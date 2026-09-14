#!/usr/bin/env bash
# =============================================================
# custome_kernel_config_new.sh
# ImmortalWrt NanoPi R5S 编译配置 + 构建脚本
#
# 负责：
#   1. ccache 初始化 + staging_dir 缓存完整性验证
#   2. 6.12 内核产物验证 + 版本解析（从 target/linux/generic/kernel-6.12）
#   3. 初始化 .config（目标设备 + Docker + PCIe + luci-app-amlogic）
#   4. 集成 luci-app-amlogic + 执行 add_packages.sh
#   5. .config 去重
#   6. 修补 file Makefile 依赖
#   7. 强制修正关键配置 + 一次性同步（oldconfig + defconfig）
#   8. 清理污染的 go-mod-cache + 下载软件包源码
#   9. 冻结配置，分阶段编译（tools → toolchain → target → package → final）
# =============================================================

set -e

# ---------- 路径解析 ----------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PROJECT_DIR="$REPO_ROOT/project"
FRIENDLYWRT_DIR="$PROJECT_DIR/friendlywrt"
SCRIPTS_DIR="$SCRIPT_DIR"

# ---------- 环境变量默认值 ----------
: "${ROOTFS_PARTSIZE:=1024}"
: "${CCACHE_DIR:=$HOME/.ccache}"
: "${CCACHE_MAXSIZE:=3G}"

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
    HOST_GCC=$(find "$STAGING/host/bin" -maxdepth 1 \
        \( -name "gcc" -o -name "*-gcc" -o -name "gcc-*" \) \
        2>/dev/null | head -1)

    TOOLCHAIN_DIR=$(find "$STAGING" -maxdepth 1 -type d -name "toolchain-*" 2>/dev/null | head -1)
    TC_GCC=""
    if [ -n "$TOOLCHAIN_DIR" ]; then
        TC_GCC=$(find "$TOOLCHAIN_DIR/bin" -maxdepth 1 \
            \( -name "*-gcc" -o -name "*-gcc-*" \) \
            2>/dev/null | head -1)
    fi

    log "  host gcc: ${HOST_GCC:-(未找到)}"
    log "  toolchain dir: ${TOOLCHAIN_DIR:-(未找到)}"
    log "  toolchain gcc: ${TC_GCC:-(未找到)}"

    local MISSING=0
    [ -z "$HOST_GCC" ] && { warn "host gcc 未找到"; MISSING=1; }
    [ -z "$TOOLCHAIN_DIR" ] && { warn "toolchain 目录未找到"; MISSING=1; }
    [ -z "$TC_GCC" ] && { warn "toolchain gcc 未找到"; MISSING=1; }

    if [ "$MISSING" = "1" ]; then
        warn "staging_dir 缓存不完整，删除以避免半损坏状态"
        rm -rf "$STAGING"
        log "[OK] 已清除 staging_dir，将重新编译 tools + toolchain"
    else
        log "[OK] staging_dir 缓存完整，跳过 tools + toolchain 编译"
    fi
}

# =============================================================
# 2. 6.12 内核产物验证 + 版本号解析
# =============================================================
step_verify_kernel() {
    log "===== 2. 验证 6.12 内核产物 ====="
    cd "$FRIENDLYWRT_DIR"

    [ -d "target/linux/rockchip/patches-6.12" ]      || err "6.12 内核补丁目录不存在"
    [ -f "target/linux/rockchip/armv8/config-6.12" ] || err "6.12 内核配置文件不存在"
    log "[OK] 6.12 内核产物已就绪"

    local KVER_FILE="target/linux/generic/kernel-6.12"
    [ -f "$KVER_FILE" ] || err "内核版本文件不存在: $KVER_FILE"

    local VP
    VP=$(grep -oE "^LINUX_VERSION-6\.12 = \.[0-9]+" "$KVER_FILE" \
         | head -1 | awk '{print $3}')

    [ -n "$VP" ] || err "无法从 $KVER_FILE 中解析 6.12.x 内核版本号"

    local KVER="6.12${VP}"
    log "[INFO] 内核版本: $KVER"

    local PATCH
    PATCH=$(echo "$KVER" | cut -d. -f3)
    if [ "$PATCH" -lt 17 ] 2>/dev/null; then
        warn "内核版本 $KVER < 6.12.17，可能缺少 PCIe 修复补丁"
        warn "R5S LAN 口（PCIe 转接）可能无法识别"
    else
        log "[OK] 内核版本 $KVER 已包含 PCIe 修复补丁（>= 6.12.17）"
    fi
}

# =============================================================
# 3. 初始化 .config
# =============================================================
step_init_config() {
    log "===== 3. 初始化 .config ====="
    cd "$FRIENDLYWRT_DIR"
    cat > .config <<EOF
CONFIG_TARGET_rockchip=y
CONFIG_TARGET_rockchip_armv8=y
CONFIG_TARGET_rockchip_armv8_DEVICE_friendlyarm_nanopi-r5s=y
CONFIG_LUCI_LANG_zh_Hans=y
CONFIG_CCACHE=y
CONFIG_CCACHE_DIR="$CCACHE_DIR"
CONFIG_TARGET_ROOTFS_PARTSIZE=$ROOTFS_PARTSIZE

CONFIG_LINUX_6_12=y

CONFIG_PCIE_ROCKCHIP_DW_HOST=y
CONFIG_PHY_ROCKCHIP_NANENG_COMBPHY=y

CONFIG_PACKAGE_docker=y
CONFIG_PACKAGE_dockerd=y
CONFIG_PACKAGE_docker-compose=y
CONFIG_PACKAGE_luci-app-dockerman=y
CONFIG_PACKAGE_luci-i18n-dockerman-zh-cn=y
CONFIG_PACKAGE_luci-lib-docker=y
CONFIG_DOCKER_KERNEL_OPTIONS=y
CONFIG_DOCKER_NET_OVERLAY=y

CONFIG_PACKAGE_luci-app-amlogic=y
EOF
    yes "" 2>/dev/null | make oldconfig > /dev/null 2>&1 || make defconfig > /dev/null 2>&1
    log "[OK] .config 初始化完成"
    grep -E "^CONFIG_(CCACHE|TARGET_ROOTFS_PARTSIZE|PACKAGE_docker|PACKAGE_dockerd|PACKAGE_luci-app-dockerman|PACKAGE_luci-app-amlogic|PCIE_ROCKCHIP|PHY_ROCKCHIP|DOCKER_|LINUX_6)" .config || true
}

# =============================================================
# 4. 应用自定义配置（含 luci-app-amlogic 集成）
# =============================================================
step_apply_customizations() {
    log "===== 4. 应用自定义配置 ====="

    log "克隆 luci-app-amlogic 插件..."
    cd "$FRIENDLYWRT_DIR"
    rm -rf package/luci-app-amlogic
    git clone --depth 1 -b main https://github.com/ophub/luci-app-amlogic.git package/luci-app-amlogic
    [ -d "package/luci-app-amlogic" ] || err "luci-app-amlogic 克隆失败"
    log "[OK] luci-app-amlogic 已克隆到 package/luci-app-amlogic"

    local add_pkgs="$SCRIPTS_DIR/add_packages.sh"
    if [ -f "$add_pkgs" ]; then
        log "修复 add_packages.sh 内核配置路径..."
        log "  before: $(grep -n 'KERNEL_CONFIG_FILE=' "$add_pkgs" || true)"
        sed -i 's|KERNEL_CONFIG_FILE="target/linux/rockchip/config-\${KERNEL_VERSION}"|KERNEL_CONFIG_FILE="target/linux/rockchip/armv8/config-\${KERNEL_VERSION}"|' "$add_pkgs"
        log "  after:  $(grep -n 'KERNEL_CONFIG_FILE=' "$add_pkgs" || true)"

        cd "$PROJECT_DIR"
        bash "$add_pkgs"
        log "[OK] add_packages.sh 执行完成"
    else
        warn "add_packages.sh 不存在，跳过"
    fi

    log "确保 luci-app-amlogic 依赖包已启用..."
    cd "$FRIENDLYWRT_DIR"

    local AML_DEPS="
        luci-base
        luci-compat
        luci-lib-jsonc
        luci-lib-nixio
        block-mount
        e2fsprogs
        tune2fs
        tar
        gzip
        curl
        wget
        unzip
        dosfstools
        parted
        coreutils
        coreutils-stat
        kmod-fs-vfat
        kmod-fs-ext4
        kmod-fs-btrfs
    "

    for pkg in $AML_DEPS; do
        sed -i "/^# CONFIG_PACKAGE_${pkg} is not set/d" .config 2>/dev/null || true
        sed -i "/^CONFIG_PACKAGE_${pkg}=/d" .config 2>/dev/null || true
        echo "CONFIG_PACKAGE_${pkg}=y" >> .config
    done
    log "[OK] luci-app-amlogic 依赖包已启用"

    sed -i "/^# CONFIG_PACKAGE_luci-app-amlogic is not set/d" .config 2>/dev/null || true
    sed -i "/^CONFIG_PACKAGE_luci-app-amlogic=/d" .config 2>/dev/null || true
    echo "CONFIG_PACKAGE_luci-app-amlogic=y" >> .config

    log "[OK] luci-app-amlogic 已启用"
    grep -E "CONFIG_PACKAGE_(luci-app-amlogic|tune2fs|block-mount|e2fsprogs)" .config || true
}

# =============================================================
# 5. .config 去重
# =============================================================
step_dedupe_config() {
    log "===== 5. .config 去重 ====="
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
# 6. 修补 file Makefile 依赖
# =============================================================
step_patch_file_makefile() {
    log "===== 6. 修补 file Makefile 依赖 ====="
    cd "$FRIENDLYWRT_DIR"

    local FILE_MK="feeds/packages/libs/file/Makefile"
    if [ ! -f "$FILE_MK" ]; then
        warn "$FILE_MK 不存在（feeds 可能未安装或版本不同），跳过"
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
# 7. 强制修正关键配置 + 一次性同步（核心修复点）
# =============================================================
step_force_config() {
    log "===== 7. 强制修正关键配置 + 一次性同步 ====="
    cd "$FRIENDLYWRT_DIR"

    # ---- ccache ----
    sed -i '/^CONFIG_CCACHE_DIR=/d' .config
    sed -i '/^# CONFIG_CCACHE_DIR is not set/d' .config
    echo "CONFIG_CCACHE_DIR=\"$CCACHE_DIR\"" >> .config
    sed -i '/^CONFIG_CCACHE=/d' .config
    sed -i '/^# CONFIG_CCACHE is not set/d' .config
    echo "CONFIG_CCACHE=y" >> .config

    # ---- rootfs ----
    sed -i '/^CONFIG_TARGET_ROOTFS_PARTSIZE=/d' .config
    sed -i '/^# CONFIG_TARGET_ROOTFS_PARTSIZE is not set/d' .config
    echo "CONFIG_TARGET_ROOTFS_PARTSIZE=$ROOTFS_PARTSIZE" >> .config

    # ---- docker 相关 ----
    local pkg
    for pkg in docker dockerd docker-compose luci-app-dockerman luci-i18n-dockerman-zh-cn luci-lib-docker; do
        sed -i "/^CONFIG_PACKAGE_${pkg}=/d" .config
        sed -i "/^# CONFIG_PACKAGE_${pkg} is not set/d" .config
        echo "CONFIG_PACKAGE_${pkg}=y" >> .config
    done

    sed -i '/^CONFIG_DOCKER_KERNEL_OPTIONS=/d' .config
    echo "CONFIG_DOCKER_KERNEL_OPTIONS=y" >> .config
    sed -i '/^CONFIG_DOCKER_NET_OVERLAY=/d' .config
    echo "CONFIG_DOCKER_NET_OVERLAY=y" >> .config

    # ---- 内核 ----
    sed -i '/^CONFIG_LINUX_6_12=/d' .config
    echo "CONFIG_LINUX_6_12=y" >> .config

    # ---- PCIe ----
    sed -i '/^CONFIG_PCIE_ROCKCHIP_DW_HOST=/d' .config
    echo "CONFIG_PCIE_ROCKCHIP_DW_HOST=y" >> .config
    sed -i '/^CONFIG_PHY_ROCKCHIP_NANENG_COMBPHY=/d' .config
    echo "CONFIG_PHY_ROCKCHIP_NANENG_COMBPHY=y" >> .config

    # ---- amlogic ----
    sed -i "/^# CONFIG_PACKAGE_luci-app-amlogic is not set/d" .config 2>/dev/null || true
    sed -i "/^CONFIG_PACKAGE_luci-app-amlogic=/d" .config 2>/dev/null || true
    echo "CONFIG_PACKAGE_luci-app-amlogic=y" >> .config

    # ============================================================
    # 【关键修复】所有 .config 写入集中在此，末尾统一同步一次。
    # 这一步重算 tmp/.config-package.in，彻底消除
    #   "WARNING: your configuration is out of sync"
    # 之后编译期间不再修改 .config。
    # ============================================================
    log "同步 .config 与 tmp/.config-package.in ..."
    yes "" 2>/dev/null | make oldconfig > /dev/null 2>&1 || true
    make defconfig > /dev/null 2>&1 || true

    log "[OK] 关键配置已强制修正并同步（配置已冻结）"
    grep -E "^CONFIG_(CCACHE|TARGET_ROOTFS_PARTSIZE|PACKAGE_docker|PACKAGE_dockerd|PACKAGE_luci-app-dockerman|PACKAGE_luci-app-amlogic|PCIE_ROCKCHIP|PHY_ROCKCHIP|DOCKER_|LINUX_6)" .config
}

# =============================================================
# 8. 清理污染的 go-mod-cache + 下载软件包源码
# =============================================================
step_download_packages() {
    log "===== 8. 下载软件包源码 ====="
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
# 9. 编译前配置只读校验（不修改 .config）
# =============================================================
verify_critical_cfg() {
    local checks=(
        "^CONFIG_CCACHE=y"
        "^CONFIG_TARGET_ROOTFS_PARTSIZE=$ROOTFS_PARTSIZE"
        "^CONFIG_LINUX_6_12=y"
        "^CONFIG_PCIE_ROCKCHIP_DW_HOST=y"
        "^CONFIG_PHY_ROCKCHIP_NANENG_COMBPHY=y"
        "^CONFIG_PACKAGE_luci-app-amlogic=y"
        "^CONFIG_DOCKER_KERNEL_OPTIONS=y"
        "^CONFIG_PACKAGE_docker=y"
        "^CONFIG_PACKAGE_dockerd=y"
        "^CONFIG_PACKAGE_docker-compose=y"
        "^CONFIG_PACKAGE_luci-app-dockerman=y"
        "^CONFIG_PACKAGE_luci-i18n-dockerman-zh-cn=y"
        "^CONFIG_PACKAGE_luci-lib-docker=y"
    )
    local pat
    for pat in "${checks[@]}"; do
        if ! grep -qE "$pat" .config; then
            err "编译前配置校验失败：缺少 $pat （说明第 7 步同步有遗漏）"
        fi
    done
    log "[OK] 编译前配置校验通过（配置已冻结，编译期间不再修改）"
}

# =============================================================
# 10. 分阶段编译（配置已冻结，一次通过）
# =============================================================
step_compile() {
    log "===== 9. 编译（配置已冻结，单次执行）====="
    cd "$FRIENDLYWRT_DIR"

    verify_critical_cfg

    local s LOG
    for s in tools/compile toolchain/compile target/compile package/compile; do
        log "---- STAGE: $s ----"
        LOG="/tmp/build_$(echo "$s" | tr '/' '_').log"
        if ! make -j"$(nproc)" "$s" > "$LOG" 2>&1; then
            warn "STAGE FAILED: $s"
            grep -E "ERROR: (target|package|toolchain|tool)/[^ ]+ failed" "$LOG" | tail -20 || true
            tail -120 "$LOG"
            err "编译失败: $s （详见 $LOG）"
        fi
        log "[DONE] $s"
    done

    log "---- STAGE: final make ----"
    LOG="/tmp/build_final.log"
    if ! make -j"$(nproc)" > "$LOG" 2>&1; then
        warn "final make 失败"
        grep -E "ERROR: (target|package|toolchain|tool)/[^ ]+ failed" "$LOG" | tail -10 || true
        tail -120 "$LOG"
        err "final make 失败（详见 $LOG）"
    fi
    log "[DONE] final make"

    log "=== OpenWrt 编译完成 ==="
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
    log "========================================"

    step_setup_ccache_and_staging
    step_verify_kernel
    step_init_config
    step_apply_customizations
    step_dedupe_config
    step_patch_file_makefile
    step_force_config            # 末尾已包含 oldconfig + defconfig 同步，配置冻结
    step_download_packages       # 不再触碰 .config
    step_compile                 # 只做校验，一次编译

    log "========================================"
    log "全部步骤完成"
    log "========================================"
}

main "$@"