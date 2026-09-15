#!/usr/bin/env bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PROJECT_DIR="$REPO_ROOT/project"
FRIENDLYWRT_DIR="$PROJECT_DIR/friendlywrt"
SCRIPTS_DIR="$SCRIPT_DIR"

: "${ROOTFS_PARTSIZE:=2048}"
: "${CCACHE_DIR:=$HOME/.ccache}"
: "${CCACHE_MAXSIZE:=3G}"
: "${IMMORTALWRT:=1}"

log()  { echo "[$(date +%H:%M:%S)] $*"; }
warn() { echo "[$(date +%H:%M:%S)] WARN: $*" >&2; }
info() { echo "[$(date +%H:%M:%S)] INFO: $*"; }
err()  { echo "[$(date +%H:%M:%S)] ERROR: $*" >&2; exit 1; }

[ -d "$FRIENDLYWRT_DIR" ] || err "friendlywrt 源码目录不存在: $FRIENDLYWRT_DIR"
[ -f "$SCRIPTS_DIR/add_packages.sh" ] || warn "add_packages.sh 不存在"

# =============================================================
step_setup_ccache_and_staging() {
    log "===== 1. ccache + staging_dir 验证 ====="

    mkdir -p "$CCACHE_DIR"
    ccache --max-size="$CCACHE_MAXSIZE"
    ccache --set-config=compression=true
    ccache --set-config=compiler_check=mtime
    ccache --set-config=cache_dir="$CCACHE_DIR"
    ccache -s || true

    local STAGING="$FRIENDLYWRT_DIR/staging_dir"
    [ -d "$STAGING" ] || { log "staging_dir 不存在（首次编译）"; return 0; }
    du -sh "$STAGING" 2>/dev/null || true

    local HOST_GCC TC_GCC TOOLCHAIN_DIR
    HOST_GCC=$(find "$STAGING/host/bin" -maxdepth 1 -name "*-gcc*" 2>/dev/null | head -1)
    TOOLCHAIN_DIR=$(find "$STAGING" -maxdepth 1 -type d -name "toolchain-*" 2>/dev/null | head -1)
    TC_GCC=""
    [ -n "$TOOLCHAIN_DIR" ] && TC_GCC=$(find "$TOOLCHAIN_DIR/bin" -maxdepth 1 -name "*-gcc" 2>/dev/null | head -1)

    if [ -z "$HOST_GCC" ] || [ -z "$TC_GCC" ]; then
        warn "staging_dir 缓存不完整，删除"
        rm -rf "$STAGING"
    else
        log "[OK] staging_dir 完整 (host: $HOST_GCC)"
    fi
}

# =============================================================
step_verify_kernel() {
    log "===== 2. 探测内核产物 ====="
    cd "$FRIENDLYWRT_DIR"

    local RC_DIR="target/linux/rockchip"
    [ -d "$RC_DIR" ] || { warn "$RC_DIR 不存在"; return 0; }

    local KVER=""
    [ -f "$RC_DIR/Makefile" ] && KVER=$(awk -F'[:=]' '/^KERNEL_PATCHVER/ {gsub(/[ \t]/,"",$2); print $2; exit}' "$RC_DIR/Makefile" 2>/dev/null || true)
    echo "KERNEL_PATCHVER=${KVER:-未声明}"

    find "$RC_DIR" -maxdepth 3 -type d -name "patches-*" 2>/dev/null | head -5 || true
    find "$RC_DIR" -maxdepth 3 -type f -name "config-*"  2>/dev/null | head -5 || true
    log "[OK] 内核产物探测完成"
}

# =============================================================
# add_packages.sh 硬编码 config-${KERNEL_VERSION}（默认 6.1），
# 通过软链 config-6.1/config-6.6 → armv8/config-6.12 兼容。
# =============================================================
step_bridge_kernel_config() {
    log "===== 3. 桥接内核配置路径 ====="
    cd "$FRIENDLYWRT_DIR/target/linux/rockchip" || return 0

    local TARGET_CFG=""
    for f in armv8/config-6.12 config-6.12; do
        [ -f "$f" ] && { TARGET_CFG="$f"; break; }
    done
    [ -z "$TARGET_CFG" ] && TARGET_CFG=$(find . -maxdepth 2 -name "config-*" -type f 2>/dev/null | head -1)
    [ -z "$TARGET_CFG" ] && { warn "找不到内核 config"; return 0; }

    log "真实内核 config: $TARGET_CFG"
    for ver in 6.1 6.6; do
        [ ! -e "config-$ver" ] && ln -s "$TARGET_CFG" "config-$ver" && info "软链 config-$ver -> $TARGET_CFG"
    done
    ls -la config-* 2>/dev/null || true
}

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

# Docker
CONFIG_PACKAGE_docker=y
CONFIG_PACKAGE_dockerd=y
CONFIG_PACKAGE_docker-compose=y
CONFIG_PACKAGE_luci-app-dockerman=y
CONFIG_PACKAGE_luci-i18n-dockerman-zh-cn=y
CONFIG_PACKAGE_luci-lib-docker=y
CONFIG_DOCKER_NET_OVERLAY=y

# luci-app-amlogic (晶晨宝盒)
CONFIG_PACKAGE_luci-app-amlogic=y
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
EOF

    yes "" 2>/dev/null | make oldconfig > /dev/null 2>&1 || make defconfig > /dev/null 2>&1

    log "[OK] .config 初始化完成"
    for k in CONFIG_CCACHE CONFIG_TARGET_ROOTFS_PARTSIZE \
             CONFIG_PACKAGE_docker CONFIG_PACKAGE_dockerd \
             CONFIG_PACKAGE_luci-app-dockerman \
             CONFIG_PACKAGE_luci-app-amlogic \
             CONFIG_PACKAGE_parted CONFIG_PACKAGE_e2fsprogs; do
        grep -qE "^$k=" .config && echo "  [OK]   $k" || echo "  [INFO] $k 未在 .config（内核项由 add_packages.sh 处理）"
    done
}

# =============================================================
step_apply_customizations() {
    log "===== 5. 应用自定义配置 ====="

    log "克隆 luci-app-amlogic..."
    local AML_DIR="$FRIENDLYWRT_DIR/package/luci-app-amlogic"
    rm -rf "$AML_DIR"
    if git clone --depth 1 -b main https://github.com/ophub/luci-app-amlogic.git "$AML_DIR" 2>&1 | tail -2; then
        log "[OK] luci-app-amlogic 克隆成功"
    else
        warn "luci-app-amlogic 克隆失败"
    fi

    # 克隆后刷新包索引，否则 .config 认不出这个包
    cd "$FRIENDLYWRT_DIR"
    make defconfig > /dev/null 2>&1 || true
    sed -i '/^# CONFIG_PACKAGE_luci-app-amlogic is not set/d' .config
    sed -i '/^CONFIG_PACKAGE_luci-app-amlogic=/d' .config
    echo "CONFIG_PACKAGE_luci-app-amlogic=y" >> .config
    yes "" 2>/dev/null | make oldconfig > /dev/null 2>&1 || true

    local add_pkgs="$SCRIPTS_DIR/add_packages.sh"
    if [ -f "$add_pkgs" ]; then
        # 修正 add_packages.sh 里硬编码的 kernel config 路径
        sed -i 's|KERNEL_CONFIG_FILE="target/linux/rockchip/config-\${KERNEL_VERSION}"|KERNEL_CONFIG_FILE="target/linux/rockchip/armv8/config-\${KERNEL_VERSION}"|' "$add_pkgs"
        cd "$PROJECT_DIR"
        bash "$add_pkgs"
        log "[OK] add_packages.sh 执行完成"
    fi
}

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
    log "[OK] 去重: $before → $after"
}

# =============================================================
step_patch_file_makefile() {
    log "===== 7. 修补 file Makefile ====="
    cd "$FRIENDLYWRT_DIR"

    local FILE_MK="feeds/packages/libs/file/Makefile"
    [ -f "$FILE_MK" ] || { info "$FILE_MK 不存在，跳过"; return 0; }

    yes "" 2>/dev/null | make oldconfig > /dev/null 2>&1 || true

    python3 - "$FILE_MK" <<'PY'
import re, sys, pathlib
p = pathlib.Path(sys.argv[1])
txt = p.read_text()
m = re.search(r'(define Package/libmagic\b.*?DEPENDS:=)([^\n]*)', txt, flags=re.S)
if not m:
    print("PATTERN NOT FOUND"); sys.exit(0)
deps = m.group(2); added = []
for r in ['+libbz2', '+liblzma']:
    if r not in deps: deps += " " + r; added.append(r)
if added:
    p.write_text(txt[:m.start(2)] + deps + txt[m.end(2):])
    print(f"PATCHED: {added}")
else:
    print("No change")
PY

    local SYMS="PACKAGE_libbz2 PACKAGE_liblzma PACKAGE_zlib"
    local hint found
    for hint in libbz2 liblzma zlib; do
        found=$(grep -oE "config PACKAGE_${hint}[-0-9._]*" tmp/.config-package.in 2>/dev/null | awk '{print $2}' | sort -u || true)
        SYMS="${SYMS} ${found}"
    done
    for sym in $SYMS; do
        [ -z "$sym" ] && continue
        sed -i "/^# CONFIG_${sym} is not set/d" .config
        sed -i "/^CONFIG_${sym}=/d" .config
        echo "CONFIG_${sym}=y" >> .config
    done
    yes "" 2>/dev/null | make oldconfig > /dev/null 2>&1 || true
    log "[OK] file Makefile 已修补"
}

# =============================================================
step_force_config() {
    log "===== 8. 强制修正关键配置 ====="
    cd "$FRIENDLYWRT_DIR"

    sed -i '/^CONFIG_CCACHE_DIR=/d; /^# CONFIG_CCACHE_DIR is not set/d' .config
    echo "CONFIG_CCACHE_DIR=\"$CCACHE_DIR\"" >> .config
    sed -i '/^CONFIG_CCACHE=/d; /^# CONFIG_CCACHE is not set/d' .config
    echo "CONFIG_CCACHE=y" >> .config
    sed -i '/^CONFIG_TARGET_ROOTFS_PARTSIZE=/d; /^# CONFIG_TARGET_ROOTFS_PARTSIZE is not set/d' .config
    echo "CONFIG_TARGET_ROOTFS_PARTSIZE=$ROOTFS_PARTSIZE" >> .config
    sed -i '/^CONFIG_DOCKER_NET_OVERLAY=/d' .config
    echo "CONFIG_DOCKER_NET_OVERLAY=y" >> .config

    local pkg
    for pkg in docker dockerd docker-compose luci-app-dockerman luci-i18n-dockerman-zh-cn luci-lib-docker \
               luci-app-amlogic luci-lib-nixio block-mount blkid parted dosfstools e2fsprogs jq lsblk pv losetup uuidgen bash perl fdisk; do
        sed -i "/^CONFIG_PACKAGE_${pkg}=/d; /^# CONFIG_PACKAGE_${pkg} is not set/d" .config
        echo "CONFIG_PACKAGE_${pkg}=y" >> .config
    done

    log "[OK] 关键配置已强制修正"
}

# =============================================================
step_download_packages() {
    log "===== 9. 下载软件包源码 ====="
    cd "$FRIENDLYWRT_DIR"

    [ -d "dl/go-mod-cache" ] && rm -rf dl/go-mod-cache

    make download -j"$(nproc)" > /tmp/dl1.log 2>&1 || true
    find dl -type f -size -1024c -delete 2>/dev/null || true
    make download -j"$(nproc)" > /tmp/dl2.log 2>&1 || true
    log "[OK] dl: $(find dl -type f | wc -l) 文件, $(du -sh dl | awk '{print $1}')"
}

# =============================================================
restore_critical_cfg() {
    local need_save=false
    grep -q "^CONFIG_CCACHE_DIR=\"$CCACHE_DIR\"" .config || {
        sed -i '/^CONFIG_CCACHE_DIR=/d; /^# CONFIG_CCACHE_DIR is not set/d' .config
        echo "CONFIG_CCACHE_DIR=\"$CCACHE_DIR\"" >> .config; need_save=true; }
    grep -q "^CONFIG_CCACHE=y" .config || { echo "CONFIG_CCACHE=y" >> .config; need_save=true; }
    grep -q "^CONFIG_TARGET_ROOTFS_PARTSIZE=$ROOTFS_PARTSIZE" .config || {
        sed -i '/^CONFIG_TARGET_ROOTFS_PARTSIZE=/d' .config
        echo "CONFIG_TARGET_ROOTFS_PARTSIZE=$ROOTFS_PARTSIZE" >> .config; need_save=true; }

    local pkg
    for pkg in docker dockerd docker-compose luci-app-dockerman luci-i18n-dockerman-zh-cn luci-lib-docker \
               luci-app-amlogic luci-lib-nixio block-mount blkid parted dosfstools e2fsprogs jq lsblk pv losetup uuidgen bash perl fdisk; do
        grep -q "^CONFIG_PACKAGE_${pkg}=y" .config || {
            sed -i "/^CONFIG_PACKAGE_${pkg}=/d; /^# CONFIG_PACKAGE_${pkg} is not set/d" .config
            echo "CONFIG_PACKAGE_${pkg}=y" >> .config; need_save=true; }
    done
    [ "$need_save" = "true" ] && log "[CFG] 已恢复关键配置"
    return 0
}

# =============================================================
step_compile() {
    log "===== 10. 分阶段编译 ====="
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
            [ -n "$FAILED" ] && make -j1 V=s "$FAILED/compile" 2>&1 | tail -150 || true
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
        warn "首次 final make 失败，启动诊断..."
        grep -E "ERROR: (target|package|toolchain|tool)/[^ ]+ failed" "$LOG" | tail -10 || true

        if grep -qE "out of space|failed to allocate" "$LOG"; then
            local ROOTFS_DIR ACTUAL_MB NEEDED_MB NEW_PARTSIZE
            ROOTFS_DIR=$(find build_dir/target-* -maxdepth 1 -type d -name "root-*" | head -1)
            if [ -n "$ROOTFS_DIR" ]; then
                ACTUAL_MB=$(du -s -m "$ROOTFS_DIR" | awk '{print $1}')
                NEEDED_MB=$(( (ACTUAL_MB + 64 + 63) / 64 * 64 ))
                NEW_PARTSIZE=$(( NEEDED_MB + 256 ))
                log "rootfs: ${ACTUAL_MB} MB → 新分区: ${NEW_PARTSIZE} MB"
                sed -i '/^CONFIG_TARGET_ROOTFS_PARTSIZE=/d' .config
                echo "CONFIG_TARGET_ROOTFS_PARTSIZE=$NEW_PARTSIZE" >> .config
            fi
        fi

        if grep -qE "ERROR: target/linux failed" "$LOG" && ! grep -qE "out of space" "$LOG"; then
            make defconfig > /dev/null 2>&1 || true
            yes "" 2>/dev/null | make oldconfig > /dev/null 2>&1 || true
            restore_critical_cfg > /dev/null 2>&1
            make -j1 V=s target/linux/install 2>&1 | tee /tmp/kernel_install.log | tail -100 || true
        fi

        local FAILED_PKG
        FAILED_PKG=$(grep -oE "ERROR: package/[^ ]+ failed" "$LOG" | head -1 | sed 's|ERROR: ||; s| failed||')
        [ -n "$FAILED_PKG" ] && make -j1 V=s "$FAILED_PKG/compile" 2>&1 | tail -200 || true

        log "----- 重试完整 final make -----"
        restore_critical_cfg > /dev/null 2>&1
        make -j"$(nproc)" > /tmp/build_final_retry.log 2>&1 || err "重试仍失败（详见 /tmp/build_final_retry.log）"
        log "[DONE] final make (retry)"
    fi

    log "=== 编译完成 ==="
    ls -lh bin/targets/rockchip/armv8/*.img.gz 2>/dev/null || echo "(未找到原生镜像)"
}

# =============================================================
main() {
    log "ImmortalWrt R5S 编译脚本启动"
    log "ROOTFS_PARTSIZE=$ROOTFS_PARTSIZE  CCACHE_DIR=$CCACHE_DIR"

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

    log "全部步骤完成"
}

main "$@"