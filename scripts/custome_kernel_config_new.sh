#!/usr/bin/env bash
# ImmortalWrt (rockchip/armv8, NanoPi R5S) 6.12 内核编译脚本
# 集成 luci-app-amlogic (晶晨宝盒)
set -e

# ---------- 路径解析 ----------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PROJECT_DIR="$REPO_ROOT/project"
FRIENDLYWRT_DIR="$PROJECT_DIR/friendlywrt"
SCRIPTS_DIR="$SCRIPT_DIR"

# ---------- 环境变量默认值 ----------
: "${ROOTFS_PARTSIZE:=2048}"
: "${CCACHE_DIR:=$HOME/.ccache}"
: "${CCACHE_MAXSIZE:=3G}"
: "${IMMORTALWRT:=1}"

# ---------- 日志 ----------
log()  { echo "[$(date +%H:%M:%S)] $*"; }
warn() { echo "[$(date +%H:%M:%S)] WARN: $*" >&2; }
err()  { echo "[$(date +%H:%M:%S)] ERROR: $*" >&2; exit 1; }

# ---------- 前置检查 ----------
[ -d "$FRIENDLYWRT_DIR" ] || err "friendlywrt 源码目录不存在: $FRIENDLYWRT_DIR"
[ -f "$SCRIPTS_DIR/add_packages.sh" ] || warn "add_packages.sh 不存在: $SCRIPTS_DIR/add_packages.sh"

# =============================================================
# 1. ccache 初始化 + staging_dir 缓存完整性验证
# =============================================================
step_setup_ccache_and_staging() {
    log "===== 1. ccache 初始化 + staging_dir 验证 ====="

    mkdir -p "$CCACHE_DIR"
    ccache --max-size="$CCACHE_MAXSIZE"
    ccache --set-config=compression=true
    ccache --set-config=compiler_check=mtime
    ccache --set-config=cache_dir="$CCACHE_DIR"
    ccache -p 2>/dev/null | grep -E "cache_dir|max_size|compression|compiler_check" || true
    ccache -s || true

    local STAGING="$FRIENDLYWRT_DIR/staging_dir"
    if [ ! -d "$STAGING" ]; then
        log "[INFO] staging_dir 不存在（首次编译）"
        return 0
    fi

    log "=== staging_dir 结构 ==="
    du -sh "$STAGING" 2>/dev/null || true

    local HOST_GCC TOOLCHAIN_DIR TC_GCC
    HOST_GCC=$(find "$STAGING/host/bin" -maxdepth 1 -name "*-gcc*" 2>/dev/null | head -1)
    TOOLCHAIN_DIR=$(find "$STAGING" -maxdepth 1 -type d -name "toolchain-*" 2>/dev/null | head -1)
    TC_GCC=""
    if [ -n "$TOOLCHAIN_DIR" ]; then
        TC_GCC=$(find "$TOOLCHAIN_DIR/bin" -maxdepth 1 -name "*-gcc" 2>/dev/null | head -1)
    fi

    local MISSING=0
    [ -z "$HOST_GCC" ] && { warn "host gcc 未找到"; MISSING=1; }
    [ -z "$TC_GCC" ] && { warn "toolchain gcc 未找到"; MISSING=1; }

    if [ "$MISSING" = "1" ]; then
        warn "staging_dir 缓存不完整，删除以避免半损坏状态"
        rm -rf "$STAGING"
        log "[OK] 已清除 staging_dir"
    else
        log "[OK] staging_dir 缓存完整"
        log "  host gcc: $HOST_GCC"
        log "  toolchain gcc: $TC_GCC"
    fi
}

# =============================================================
# 2. 探测内核产物（非阻塞、诊断优先）
# =============================================================
step_verify_kernel() {
    log "===== 2. 探测内核产物（不阻塞）====="
    cd "$FRIENDLYWRT_DIR"

    local RC_DIR="target/linux/rockchip"
    if [ ! -d "$RC_DIR" ]; then
        warn "$RC_DIR 不存在，打印 target/linux 顶层结构："
        ls -la target/linux/ 2>&1 | head -40 || true
        return 0
    fi

    echo "--- $RC_DIR 顶层内容 ---"
    ls -la "$RC_DIR" 2>&1 | head -40

    echo "--- $RC_DIR 子目录（最多 3 层）---"
    find "$RC_DIR" -maxdepth 3 -type d 2>/dev/null | sort | head -60

    local KVER=""
    if [ -f "$RC_DIR/Makefile" ]; then
        KVER=$(awk -F'[:=]' '/^KERNEL_PATCHVER/ {gsub(/[ \t]/,"",$2); print $2; exit}' \
                    "$RC_DIR/Makefile" 2>/dev/null || true)
    fi
    echo "KERNEL_PATCHVER=${KVER:-未声明}"

    local PATCH_DIRS CFG_FILES
    PATCH_DIRS=$(find "$RC_DIR" -maxdepth 3 -type d -name "patches-*" 2>/dev/null | head -10 || true)
    CFG_FILES=$(find  "$RC_DIR" -maxdepth 3 -type f -name "config-*"  2>/dev/null | head -10 || true)

    echo "--- patches 目录 ---"
    if [ -n "$PATCH_DIRS" ]; then echo "$PATCH_DIRS"; else echo "(无)"; fi

    echo "--- config 文件 ---"
    if [ -n "$CFG_FILES" ]; then echo "$CFG_FILES"; else echo "(无)"; fi

    if [ -z "$PATCH_DIRS" ] && [ -z "$CFG_FILES" ]; then
        warn "未探测到 patches-*/config-*，该目标可能使用纯 upstream 内核"
        warn "继续编译流程，若后续失败请回看以上目录列表"
    else
        log "[OK] 内核产物探测完成"
    fi
}

# =============================================================
# 3. 桥接内核配置路径（动态探测目标 config）
# =============================================================
step_bridge_kernel_config() {
    log "===== 3. 桥接内核配置路径 ====="
    cd "$FRIENDLYWRT_DIR/target/linux/rockchip" || { warn "无法进入 rockchip 目录"; return 0; }

    local KVER=""
    [ -f Makefile ] && KVER=$(awk -F'[:=]' '/^KERNEL_PATCHVER/ {gsub(/[ \t]/,"",$2); print $2; exit}' \
                                    Makefile 2>/dev/null || true)
    log "  KERNEL_PATCHVER=${KVER:-未声明}"

    local TARGET_CFG=""
    local CANDIDATES=""
    [ -n "$KVER" ] && CANDIDATES="armv8/config-${KVER} config-${KVER}"
    CANDIDATES="$CANDIDATES armv8/config-6.12 config-6.12 armv8/config-6.6 config-6.6"

    for f in $CANDIDATES; do
        if [ -f "$f" ]; then
            TARGET_CFG="$f"; break
        fi
    done

    if [ -z "$TARGET_CFG" ]; then
        TARGET_CFG=$(find . -maxdepth 2 -name "config-*" -type f 2>/dev/null | head -1)
    fi

    if [ -z "$TARGET_CFG" ]; then
        warn "找不到内核 config 文件，跳过桥接（不影响后续编译）"
        ls -la 2>&1 | head -30 || true
        return 0
    fi

    log "  TARGET_CFG=$TARGET_CFG"

    local LINKED=0
    for ver in 6.1 6.6; do
        if [ ! -e "config-$ver" ]; then
            ln -s "$TARGET_CFG" "config-$ver" && LINKED=1
            log "[OK] 创建 config-$ver -> $TARGET_CFG"
        fi
    done
    [ "$LINKED" = "0" ] && log "  (无需新建符号链接)"

    ls -la config-* 2>/dev/null || true
}

# =============================================================
# 4. 初始化 .config（含 luci-app-amlogic 及其依赖）
# =============================================================
step_init_config() {
    log "===== 4. 初始化 .config ====="
    cd "$FRIENDLYWRT_DIR"
    cat > .config <<EOF
CONFIG_TARGET_rockchip=y
CONFIG_TARGET_rockchip_armv8=y
CONFIG_TARGET_rockchip_armv8_DEVICE_friendlyarm_nanopi-r5s=y
CONFIG_LUCI_LANG_zh_Hans=y
CONFIG_CCACHE=y
CONFIG_CCACHE_DIR="$CCACHE_DIR"
CONFIG_TARGET_ROOTFS_PARTSIZE=$ROOTFS_PARTSIZE

# ===== Docker =====
CONFIG_PACKAGE_docker=y
CONFIG_PACKAGE_dockerd=y
CONFIG_PACKAGE_docker-compose=y
CONFIG_PACKAGE_luci-app-dockerman=y
CONFIG_PACKAGE_luci-i18n-dockerman-zh-cn=y
CONFIG_PACKAGE_luci-lib-docker=y
CONFIG_DOCKER_KERNEL_OPTIONS=y
CONFIG_DOCKER_NET_OVERLAY=y

# ===== luci-app-amlogic (晶晨宝盒) =====
CONFIG_PACKAGE_luci-app-amlogic=y

# ===== luci-app-amlogic 依赖包 =====
CONFIG_PACKAGE_luci-lib-nixio=y
CONFIG_PACKAGE_block-mount=y
CONFIG_PACKAGE_blkid=y
CONFIG_PACKAGE_parted=y
CONFIG_PACKAGE_dosfstools=y
CONFIG_PACKAGE_e2fsprogs=y
CONFIG_PACKAGE_jq=y
CONFIG_PACKAGE_lsblk=y
CONFIG_PACKAGE_pv=y
CONFIG_PACKAGE_losetup=y
CONFIG_PACKAGE_uuidgen=y
CONFIG_PACKAGE_bash=y
CONFIG_PACKAGE_perl=y
CONFIG_PACKAGE_fdisk=y

# ===== cgroup / namespace =====
CONFIG_CGROUP_SCHED=y
CONFIG_CGROUP_CPUACCT=y
CONFIG_CGROUP_BPF=y
CONFIG_CGROUP_PIDS=y
CONFIG_CGROUP_FREEZER=y
CONFIG_CGROUP_DEVICE=y
CONFIG_CGROUP_NET_CLASSID=y
CONFIG_CGROUP_NET_PRIO=y
CONFIG_MEMCG=y
CONFIG_MEMCG_SWAP=y
CONFIG_NAMESPACES=y
CONFIG_NET_NS=y
CONFIG_PID_NS=y
CONFIG_IPC_NS=y
CONFIG_UTS_NS=y
CONFIG_USER_NS=y

# ===== netfilter / iptables / bridge =====
CONFIG_BRIDGE=y
CONFIG_BRIDGE_NETFILTER=y
CONFIG_BRIDGE_VLAN_FILTERING=y
CONFIG_NF_TABLES=y
CONFIG_NF_NAT=y
CONFIG_IP_NF_NAT=y
CONFIG_IP_NF_TARGET_MASQUERADE=y
CONFIG_NETFILTER_XT_MATCH_ADDRTYPE=y
CONFIG_NETFILTER_XT_MATCH_MULTIPORT=y
CONFIG_VETH=y
CONFIG_OVERLAY_FS=y
CONFIG_OVERLAY_FS_REDIRECT_DIR=y

# ===== swap =====
CONFIG_SWAP=y
CONFIG_MEMCG_SWAP_ENABLED=y
CONFIG_ZRAM=y
CONFIG_ZSMALLOC=y
EOF

    yes "" 2>/dev/null | make oldconfig > /dev/null 2>&1 || make defconfig > /dev/null 2>&1
    log "[OK] .config 初始化完成"

    echo "=== 关键项自检 ==="
    for k in CONFIG_CCACHE CONFIG_TARGET_ROOTFS_PARTSIZE \
             CONFIG_PACKAGE_docker CONFIG_PACKAGE_dockerd \
             CONFIG_PACKAGE_luci-app-dockerman \
             CONFIG_PACKAGE_luci-app-amlogic \
             CONFIG_PACKAGE_parted CONFIG_PACKAGE_e2fsprogs \
             CONFIG_DOCKER_KERNEL_OPTIONS CONFIG_DOCKER_NET_OVERLAY \
             CONFIG_CGROUP_BPF CONFIG_MEMCG CONFIG_NET_NS \
             CONFIG_BRIDGE_NETFILTER CONFIG_NF_TABLES CONFIG_VETH \
             CONFIG_OVERLAY_FS CONFIG_IP_NF_NAT; do
        grep -E "^$k=" .config || echo "  [MISS] $k"
    done

    if ! grep -q "CONFIG_TARGET_rockchip_armv8_DEVICE_friendlyarm_nanopi-r5s=y" .config; then
        warn "DEVICE_friendlyarm_nanopi-r5s 未匹配，可能命名有差异"
        echo "=== 当前 .config 里所有 r5s 相关 ==="
        grep -iE "nanopi|r5s" .config || true
        echo "=== target/linux/rockchip/image/ 设备清单 ==="
        grep -hE "DEVICE_.*nanopi" target/linux/rockchip/image/*.mk 2>/dev/null || true
    fi
}

# =============================================================
# 5. 应用自定义（克隆 luci-app-amlogic + 修复 add_packages.sh）
# =============================================================
step_apply_customizations() {
    log "===== 5. 应用自定义配置 ====="

    # ---- 5.1 克隆 luci-app-amlogic 到 package/ ----
    log "克隆 luci-app-amlogic (晶晨宝盒)..."
    local AML_DIR="$FRIENDLYWRT_DIR/package/luci-app-amlogic"
    rm -rf "$AML_DIR"
    if git clone --depth 1 -b main https://github.com/ophub/luci-app-amlogic.git "$AML_DIR"; then
        log "[OK] luci-app-amlogic 克隆成功"
        ls -la "$AML_DIR" | head -10
    else
        warn "luci-app-amlogic 克隆失败，继续（可能导致编译时找不到该包）"
    fi

    # ---- 5.2 修复 add_packages.sh 内核路径 bug ----
    local add_pkgs="$SCRIPTS_DIR/add_packages.sh"
    if [ -f "$add_pkgs" ]; then
        log "修复 add_packages.sh 内核配置路径..."
        log "  before: $(grep -n 'KERNEL_CONFIG_FILE=' "$add_pkgs" || true)"
        sed -i 's|KERNEL_CONFIG_FILE="target/linux/rockchip/config-\${KERNEL_VERSION}"|KERNEL_CONFIG_FILE="target/linux/rockchip/armv8/config-\${KERNEL_VERSION}"|' "$add_pkgs"
        log "  after:  $(grep -n 'KERNEL_CONFIG_FILE=' "$add_pkgs" || true)"
    fi

    # ---- 5.3 执行 add_packages.sh ----
    cd "$PROJECT_DIR"
    if [ -f "$add_pkgs" ]; then
        bash "$add_pkgs"
        log "[OK] add_packages.sh 执行完成"
    fi
}

# =============================================================
# 6. .config 去重
# =============================================================
step_dedupe_config() {
    log "===== 6. .config 去重 ====="
    cd "$FRIENDLYWRT_DIR"
    local before after
    before=$(wc -l < .config)
    awk -F= '
      /^# / { print; next }
      /^CONFIG_/ {
        key = $1
        if (!(key in seen)) { keys[++n] = key; seen[key] = 1 }
        values[key] = $0
        next
      }
      { print }
      END { for (i = 1; i <= n; i++) print values[keys[i]] }
    ' .config > .config.dedup && mv .config.dedup .config
    after=$(wc -l < .config)
    log "[OK] 去重: $before 行 → $after 行"
}

# =============================================================
# 7. 修补 file Makefile 依赖
# =============================================================
step_patch_file_makefile() {
    log "===== 7. 修补 file Makefile 依赖 ====="
    cd "$FRIENDLYWRT_DIR"

    local FILE_MK="feeds/packages/libs/file/Makefile"
    if [ ! -f "$FILE_MK" ]; then
        warn "$FILE_MK 不存在，跳过（ImmortalWrt feed 可能不同）"
        return 0
    fi

    yes "" 2>/dev/null | make oldconfig > /dev/null 2>&1 || make defconfig > /dev/null 2>&1 || true

    python3 - "$FILE_MK" <<'PY'
import re, sys, pathlib
p = pathlib.Path(sys.argv[1])
txt = p.read_text()
m = re.search(r'(define Package/libmagic\b.*?DEPENDS:=)([^\n]*)', txt, flags=re.S)
if not m:
    print("PATTERN NOT FOUND")
    sys.exit(0)
deps = m.group(2)
added = []
for r in ['+libbz2', '+liblzma']:
    if r not in deps:
        deps += " " + r
        added.append(r)
if added:
    txt = txt[:m.start(2)] + deps + txt[m.end(2):]
    p.write_text(txt)
    print(f"PATCHED: {added}")
else:
    print("No change")
PY

    local SYMS="PACKAGE_libbz2 PACKAGE_liblzma PACKAGE_zlib"
    local hint found
    for hint in libbz2 liblzma zlib; do
        found=$(grep -oE "config PACKAGE_${hint}[-0-9._]*" tmp/.config-package.in 2>/dev/null \
                    | awk '{print $2}' | sort -u || true)
        SYMS="${SYMS} ${found}"
    done
    for sym in $SYMS; do
        [ -z "$sym" ] && continue
        sed -i "/^# CONFIG_${sym} is not set/d" .config
        sed -i "/^CONFIG_${sym}=/d" .config
        echo "CONFIG_${sym}=y" >> .config
    done
    yes "" 2>/dev/null | make oldconfig > /dev/null 2>&1 || make defconfig > /dev/null 2>&1
    log "[OK] file Makefile 依赖已修补"
}

# =============================================================
# 8. 强制修正关键配置
# =============================================================
step_force_config() {
    log "===== 8. 强制修正关键配置 ====="
    cd "$FRIENDLYWRT_DIR"

    sed -i '/^CONFIG_CCACHE_DIR=/d' .config
    sed -i '/^# CONFIG_CCACHE_DIR is not set/d' .config
    echo "CONFIG_CCACHE_DIR=\"$CCACHE_DIR\"" >> .config

    sed -i '/^CONFIG_CCACHE=/d' .config
    sed -i '/^# CONFIG_CCACHE is not set/d' .config
    echo "CONFIG_CCACHE=y" >> .config

    sed -i '/^CONFIG_TARGET_ROOTFS_PARTSIZE=/d' .config
    sed -i '/^# CONFIG_TARGET_ROOTFS_PARTSIZE is not set/d' .config
    echo "CONFIG_TARGET_ROOTFS_PARTSIZE=$ROOTFS_PARTSIZE" >> .config

    local pkg
    for pkg in docker dockerd docker-compose luci-app-dockerman luci-i18n-dockerman-zh-cn luci-lib-docker; do
        sed -i "/^CONFIG_PACKAGE_${pkg}=/d" .config
        sed -i "/^# CONFIG_PACKAGE_${pkg} is not set/d" .config
        echo "CONFIG_PACKAGE_${pkg}=y" >> .config
    done

    # luci-app-amlogic 及其依赖强制启用
    for pkg in luci-app-amlogic luci-lib-nixio block-mount blkid parted dosfstools e2fsprogs jq lsblk pv losetup uuidgen bash perl fdisk; do
        sed -i "/^CONFIG_PACKAGE_${pkg}=/d" .config
        sed -i "/^# CONFIG_PACKAGE_${pkg} is not set/d" .config
        echo "CONFIG_PACKAGE_${pkg}=y" >> .config
    done

    sed -i '/^CONFIG_DOCKER_KERNEL_OPTIONS=/d' .config
    echo "CONFIG_DOCKER_KERNEL_OPTIONS=y" >> .config
    sed -i '/^CONFIG_DOCKER_NET_OVERLAY=/d' .config
    echo "CONFIG_DOCKER_NET_OVERLAY=y" >> .config

    local KOPTS="
CONFIG_CGROUP_SCHED=y
CONFIG_CGROUP_CPUACCT=y
CONFIG_CGROUP_BPF=y
CONFIG_CGROUP_PIDS=y
CONFIG_CGROUP_FREEZER=y
CONFIG_CGROUP_DEVICE=y
CONFIG_CGROUP_NET_CLASSID=y
CONFIG_CGROUP_NET_PRIO=y
CONFIG_MEMCG=y
CONFIG_MEMCG_SWAP=y
CONFIG_MEMCG_SWAP_ENABLED=y
CONFIG_NAMESPACES=y
CONFIG_NET_NS=y
CONFIG_PID_NS=y
CONFIG_IPC_NS=y
CONFIG_UTS_NS=y
CONFIG_USER_NS=y
CONFIG_BRIDGE=y
CONFIG_BRIDGE_NETFILTER=y
CONFIG_BRIDGE_VLAN_FILTERING=y
CONFIG_NF_TABLES=y
CONFIG_NF_NAT=y
CONFIG_IP_NF_NAT=y
CONFIG_IP_NF_TARGET_MASQUERADE=y
CONFIG_NETFILTER_XT_MATCH_ADDRTYPE=y
CONFIG_NETFILTER_XT_MATCH_MULTIPORT=y
CONFIG_VETH=y
CONFIG_OVERLAY_FS=y
CONFIG_OVERLAY_FS_REDIRECT_DIR=y
CONFIG_SWAP=y
CONFIG_ZRAM=y
CONFIG_ZSMALLOC=y
"
    while IFS='=' read -r k v; do
        [ -z "$k" ] && continue
        k=$(echo "$k" | tr -d ' ')
        v=$(echo "$v" | tr -d ' ')
        sed -i "/^${k}=/d" .config
        sed -i "/^# ${k} is not set/d" .config
        echo "${k}=${v}" >> .config
    done <<< "$KOPTS"

    log "[OK] 关键配置已强制修正"
    echo "=== 校验 ==="
    for k in CONFIG_CCACHE CONFIG_TARGET_ROOTFS_PARTSIZE \
             CONFIG_PACKAGE_luci-app-amlogic CONFIG_PACKAGE_parted \
             CONFIG_CGROUP_BPF CONFIG_MEMCG CONFIG_NET_NS \
             CONFIG_BRIDGE_NETFILTER CONFIG_NF_TABLES CONFIG_VETH \
             CONFIG_OVERLAY_FS CONFIG_IP_NF_NAT; do
        grep -E "^$k=" .config || echo "  [MISS] $k"
    done
}

# =============================================================
# 9. 清理污染的 go-mod-cache + 下载软件包源码
# =============================================================
step_download_packages() {
    log "===== 9. 下载软件包源码 ====="
    cd "$FRIENDLYWRT_DIR"

    if [ -d "dl/go-mod-cache" ]; then
        log "清理 dl/go-mod-cache（避免跨 run 缓存污染）"
        du -sh dl/go-mod-cache 2>/dev/null || true
        rm -rf dl/go-mod-cache
    fi

    make download -j"$(nproc)" > /tmp/dl1.log 2>&1 || true
    find dl -type f -size -1024c -delete 2>/dev/null || true
    make download -j"$(nproc)" > /tmp/dl2.log 2>&1 || true
    log "[OK] dl: $(find dl -type f | wc -l) 文件, $(du -sh dl | awk '{print $1}')"
}

# =============================================================
# 编译期：恢复关键配置（供循环内调用）
# =============================================================
restore_critical_cfg() {
    local need_save=false
    if ! grep -q "^CONFIG_CCACHE_DIR=\"$CCACHE_DIR\"" .config; then
        sed -i '/^CONFIG_CCACHE_DIR=/d' .config
        sed -i '/^# CONFIG_CCACHE_DIR is not set/d' .config
        echo "CONFIG_CCACHE_DIR=\"$CCACHE_DIR\"" >> .config
        need_save=true
    fi
    if ! grep -q "^CONFIG_CCACHE=y" .config; then
        echo "CONFIG_CCACHE=y" >> .config
        need_save=true
    fi
    if ! grep -q "^CONFIG_TARGET_ROOTFS_PARTSIZE=$ROOTFS_PARTSIZE" .config; then
        sed -i '/^CONFIG_TARGET_ROOTFS_PARTSIZE=/d' .config
        sed -i '/^# CONFIG_TARGET_ROOTFS_PARTSIZE is not set/d' .config
        echo "CONFIG_TARGET_ROOTFS_PARTSIZE=$ROOTFS_PARTSIZE" >> .config
        need_save=true
    fi
    local pkg
    for pkg in docker dockerd docker-compose luci-app-dockerman luci-i18n-dockerman-zh-cn luci-lib-docker; do
        if ! grep -q "^CONFIG_PACKAGE_${pkg}=y" .config; then
            sed -i "/^CONFIG_PACKAGE_${pkg}=/d" .config
            sed -i "/^# CONFIG_PACKAGE_${pkg} is not set/d" .config
            echo "CONFIG_PACKAGE_${pkg}=y" >> .config
            need_save=true
        fi
    done
    for pkg in luci-app-amlogic luci-lib-nixio block-mount blkid parted dosfstools e2fsprogs jq lsblk pv losetup uuidgen bash perl fdisk; do
        if ! grep -q "^CONFIG_PACKAGE_${pkg}=y" .config; then
            sed -i "/^CONFIG_PACKAGE_${pkg}=/d" .config
            sed -i "/^# CONFIG_PACKAGE_${pkg} is not set/d" .config
            echo "CONFIG_PACKAGE_${pkg}=y" >> .config
            need_save=true
        fi
    done
    if ! grep -q "^CONFIG_DOCKER_KERNEL_OPTIONS=y" .config; then
        sed -i '/^CONFIG_DOCKER_KERNEL_OPTIONS=/d' .config
        echo "CONFIG_DOCKER_KERNEL_OPTIONS=y" >> .config
        need_save=true
    fi
    [ "$need_save" = "true" ] && log "[CFG] 已恢复关键配置"
    return 0
}

# =============================================================
# 10. 分阶段编译 + 失败诊断恢复
# =============================================================
step_compile() {
    log "===== 10. 开始分阶段编译 ====="
    cd "$FRIENDLYWRT_DIR"

    restore_critical_cfg > /dev/null 2>&1

    local s LOG FAILED
    for s in tools/compile toolchain/compile target/compile package/compile; do
        log "---- STAGE: $s ----"
        restore_critical_cfg > /dev/null 2>&1
        LOG="/tmp/build_$(echo "$s" | tr '/' '_').log"
        if ! make -j"$(nproc)" "$s" > "$LOG" 2>&1; then
            warn "STAGE FAILED: $s"
            FAILED=$(grep -oE "ERROR: package/[^ ]+ failed to build" "$LOG" | head -1 | awk '{print $2}')
            tail -80 "$LOG"
            if [ -n "$FAILED" ]; then
                log "=== Verbose rebuild: $FAILED ==="
                make -j1 V=s "$FAILED/compile" 2>&1 | tail -150 || true
            fi
            err "编译失败: $s"
        fi
        log "[DONE] $s"
    done

    log "---- STAGE: final make ----"
    restore_critical_cfg > /dev/null 2>&1
    LOG="/tmp/build_final.log"
    if make -j"$(nproc)" > "$LOG" 2>&1; then
        log "[DONE] final make"
    else
        warn "首次 final make 失败，启动诊断流程..."
        grep -E "ERROR: (target|package|toolchain|tool)/[^ ]+ failed" "$LOG" | tail -10 || true
        grep -E "make\[[0-9]+\]: \*\*\*" "$LOG" | tail -10 || true

        if grep -qE "out of space|failed to allocate" "$LOG"; then
            log "----- 场景 1: rootfs 空间不足，尝试扩大分区 -----"
            local ROOTFS_DIR ACTUAL_MB NEEDED_MB NEW_PARTSIZE
            ROOTFS_DIR=$(find build_dir/target-* -maxdepth 1 -type d -name "root-*" | head -1)
            if [ -n "$ROOTFS_DIR" ]; then
                ACTUAL_MB=$(du -s -m "$ROOTFS_DIR" | awk '{print $1}')
                NEEDED_MB=$(( (ACTUAL_MB + 64 + 63) / 64 * 64 ))
                NEW_PARTSIZE=$(( NEEDED_MB + 256 ))
                log "当前 rootfs: ${ACTUAL_MB} MB → 新分区: ${NEW_PARTSIZE} MB"
                sed -i '/^CONFIG_TARGET_ROOTFS_PARTSIZE=/d' .config
                echo "CONFIG_TARGET_ROOTFS_PARTSIZE=$NEW_PARTSIZE" >> .config
                rm -f build_dir/target-*/linux-rockchip_armv8/root.ext4* 2>/dev/null || true
                rm -f build_dir/target-*/linux-rockchip_armv8/root.squashfs 2>/dev/null || true
                rm -f build_dir/target-*/linux-rockchip_armv8/*.img 2>/dev/null || true
            fi
        fi

        if grep -qE "ERROR: target/linux failed" "$LOG" && ! grep -qE "out of space" "$LOG"; then
            log "----- 场景 2: target/linux 失败，尝试内核配置同步 -----"
            make defconfig > /dev/null 2>&1 || true
            yes "" 2>/dev/null | make oldconfig > /dev/null 2>&1 || true
            restore_critical_cfg > /dev/null 2>&1
            make -j1 V=s target/linux/install 2>&1 | tee /tmp/kernel_install.log | tail -100 || true
        fi

        local FAILED_PKG
        FAILED_PKG=$(grep -oE "ERROR: package/[^ ]+ failed" "$LOG" | head -1 | sed 's|ERROR: ||; s| failed||')
        if [ -n "$FAILED_PKG" ]; then
            log "----- 场景 3: $FAILED_PKG 失败，详细重跑 -----"
            make -j1 V=s "$FAILED_PKG/compile" 2>&1 | tail -200 || true
        fi

        log "----- 诊断完成，重试完整 final make -----"
        restore_critical_cfg > /dev/null 2>&1
        if ! make -j"$(nproc)" > /tmp/build_final_retry.log 2>&1; then
            err "最终 make 重试仍失败（详见 /tmp/build_final_retry.log）"
        fi
        log "[DONE] final make (retry)"
    fi

    log "=== 编译完成 ==="
    ls -la build_dir/target-*/root-* 2>/dev/null | head -5 || echo "(未找到 rootfs)"
    ls -lh bin/targets/rockchip/armv8/*.img.gz 2>/dev/null || echo "(未找到原生镜像)"
}

# =============================================================
# 主入口
# =============================================================
main() {
    log "========================================"
    log "ImmortalWrt R5S 编译脚本启动"
    log "REPO_ROOT=$REPO_ROOT"
    log "FRIENDLYWRT_DIR=$FRIENDLYWRT_DIR"
    log "ROOTFS_PARTSIZE=$ROOTFS_PARTSIZE"
    log "CCACHE_DIR=$CCACHE_DIR"
    log "IMMORTALWRT=$IMMORTALWRT"
    log "========================================"

    step_setup_ccache_and_staging
    step_verify_kernel
    step_bridge_kernel_config
    step_init_config
    step_apply_customizations
    step_dedupe_config
    step_patch_file_makefile
    step_force_config
    step_download_packages
    step_compile

    log "========================================"
    log "全部步骤完成"
    log "========================================"
}

main "$@"