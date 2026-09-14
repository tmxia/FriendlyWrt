#!/usr/bin/env bash
# =============================================================
# custome_kernel_config_new.sh
# ImmortalWrt NanoPi R5S 编译配置 + 构建脚本（重构版）
#
# 设计原则：
#   1. .config 只被写入一次，通过 scripts/config 工具
#   2. 只调用一次 make defconfig 完成索引重建
#   3. 不再分阶段编译，不再在编译期修改 .config
#   4. 失败时提取错误上下文，而不是 tail
# =============================================================

set -e

# ---------- 路径解析 ----------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PROJECT_DIR="$REPO_ROOT/project"
FRIENDLYWRT_DIR="$PROJECT_DIR/friendlywrt"

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

# =============================================================
# 软件包选择清单
#
# 说明：
#   - 每一项都会以 CONFIG_PACKAGE_<name>=y 的形式写入 .config
#   - 不存在的包会被 make defconfig 自动丢弃（并在此处警告）
#   - 不要在这里放 kmod-* 之外的裸内核 config，那些由内核 Kconfig 处理
# =============================================================
SELECTED_PACKAGES=(
    # --- Docker ---
    docker
    dockerd
    docker-compose
    luci-app-dockerman
    luci-i18n-dockerman-zh-cn
    luci-lib-docker

    # --- luci-app-amlogic 及其运行时依赖 ---
    luci-app-amlogic
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

    # --- file 包的隐式依赖（libmagic） ---
    libbz2
    liblzma
    zlib

    # --- 原 add_packages.sh 期望启用的包 ---
    clashoo
    luci-app-clashoo
    luci-i18n-clashoo-zh-cn
    kmod-inet-diag
    bc
    vsftpd
    sudo
    file
    procd
    logrotate
    lsof
    jq
    wireguard-tools
    python3-light
)

# 布尔型内核/系统选项（以 CONFIG_<name>=y 写入）
SELECTED_BOOL_CONFIGS=(
    CCACHE
    PCIE_ROCKCHIP_DW_HOST
    PHY_ROCKCHIP_NANENG_COMBPHY
    DOCKER_KERNEL_OPTIONS
    DOCKER_NET_OVERLAY
    LINUX_6_12
    LUCI_LANG_zh_Hans
)

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
    [ -z "$HOST_GCC" ]      && { warn "host gcc 未找到";        MISSING=1; }
    [ -z "$TOOLCHAIN_DIR" ] && { warn "toolchain 目录未找到";   MISSING=1; }
    [ -z "$TC_GCC" ]        && { warn "toolchain gcc 未找到";   MISSING=1; }

    if [ "$MISSING" = "1" ]; then
        warn "staging_dir 缓存不完整，删除以避免半损坏状态"
        rm -rf "$STAGING"
        log "[OK] 已清除 staging_dir，将重新编译 tools + toolchain"
    else
        log "[OK] staging_dir 缓存完整"
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

    local KVER=""
    local KVER_FILE="include/kernel-6.12"

    if [ -f "$KVER_FILE" ]; then
        local VP
        VP=$(grep -oE "^LINUX_VERSION-6\.12 = \.[0-9]+" "$KVER_FILE" 2>/dev/null \
             | head -1 | awk '{print $3}' || true)
        [ -n "$VP" ] && KVER="6.12${VP}"
    fi

    [ -z "$KVER" ] && [ -f "target/linux/generic/kernel-6.12" ] && {
        local VP
        VP=$(grep -oE "^LINUX_VERSION-6\.12 = \.[0-9]+" "target/linux/generic/kernel-6.12" 2>/dev/null \
             | head -1 | awk '{print $3}' || true)
        [ -n "$VP" ] && KVER="6.12${VP}"
    }

    if [ -z "$KVER" ]; then
        warn "内核版本号无法解析（不影响编译）"
        return 0
    fi

    log "[INFO] 内核版本: $KVER"

    local PATCH
    PATCH=$(echo "$KVER" | cut -d. -f3)
    if [ "$PATCH" -lt 17 ] 2>/dev/null; then
        warn "内核版本 $KVER < 6.12.17，可能缺少 PCIe 修复补丁"
    else
        log "[OK] 内核版本 $KVER 已包含 PCIe 修复补丁（>= 6.12.17）"
    fi
}

# =============================================================
# 3. 准备 feeds 与外部软件包
# =============================================================
step_prepare_feeds() {
    log "===== 3. 准备 feeds 与外部软件包 ====="
    cd "$FRIENDLYWRT_DIR"

    log "更新 feeds..."
    if ! ./scripts/feeds update -a > /tmp/feeds_update.log 2>&1; then
        warn "feeds update 静默失败，重新执行以显示错误："
        ./scripts/feeds update -a || err "feeds update 失败"
    fi

    log "安装 feeds..."
    if ! ./scripts/feeds install -a > /tmp/feeds_install.log 2>&1; then
        warn "feeds install 静默失败，重新执行以显示错误："
        ./scripts/feeds install -a || err "feeds install 失败"
    fi

    log "克隆 luci-app-amlogic 插件..."
    rm -rf package/luci-app-amlogic
    git clone --depth 1 -b main \
        https://github.com/ophub/luci-app-amlogic.git \
        package/luci-app-amlogic
    [ -d package/luci-app-amlogic ] || err "luci-app-amlogic 克隆失败"
    log "[OK] luci-app-amlogic 已就位于 package/luci-app-amlogic"
}

# =============================================================
# 4. 写入最小 .config（只含目标/子目标/设备）
# =============================================================
step_write_base_config() {
    log "===== 4. 写入基础 .config ====="
    cd "$FRIENDLYWRT_DIR"

    cat > .config <<EOF
CONFIG_TARGET_rockchip=y
CONFIG_TARGET_rockchip_armv8=y
CONFIG_TARGET_rockchip_armv8_DEVICE_friendlyarm_nanopi-r5s=y
EOF

    log "[OK] 基础 .config 已写入（仅目标设备）"
}

# =============================================================
# 5. 通过 scripts/config 应用所有选项（唯一修改点）
# =============================================================
step_apply_config() {
    log "===== 5. 应用配置（scripts/config）====="
    cd "$FRIENDLYWRT_DIR"

    local CFG="./scripts/config"
    [ -x "$CFG" ] || err "scripts/config 不存在或不可执行"

    # --- 字符串型 ---
    $CFG --set-str CCACHE_DIR "$CCACHE_DIR"
    $CFG --set-str LUCI_LANG_zh_Hans y   # 兼容某些分支写法，下面用 --enable 兜底

    # --- 数值型 ---
    $CFG --set-val TARGET_ROOTFS_PARTSIZE "$ROOTFS_PARTSIZE"

    # --- 布尔型系统/内核选项 ---
    local opt
    for opt in "${SELECTED_BOOL_CONFIGS[@]}"; do
        $CFG --enable "$opt"
    done

    # --- 软件包 ---
    local pkg
    for pkg in "${SELECTED_PACKAGES[@]}"; do
        $CFG --enable "PACKAGE_${pkg}"
    done

    log "[OK] 配置已应用（等待 make defconfig 规范化）"
}

# =============================================================
# 6. make defconfig —— 唯一一次索引重建
# =============================================================
step_defconfig() {
    log "===== 6. 重建配置索引（make defconfig）====="
    cd "$FRIENDLYWRT_DIR"

    if ! make defconfig > /tmp/defconfig.log 2>&1; then
        warn "make defconfig 失败，输出最后 80 行："
        tail -80 /tmp/defconfig.log
        err "make defconfig 失败"
    fi

    # 校验关键项是否被 Kconfig 接受
    local missing=()
    local check_list=(
        "CONFIG_TARGET_rockchip_armv8_DEVICE_friendlyarm_nanopi-r5s"
        "CONFIG_CCACHE"
        "CONFIG_LINUX_6_12"
        "CONFIG_PCIE_ROCKCHIP_DW_HOST"
        "CONFIG_PHY_ROCKCHIP_NANENG_COMBPHY"
        "CONFIG_DOCKER_KERNEL_OPTIONS"
        "CONFIG_DOCKER_NET_OVERLAY"
        "CONFIG_PACKAGE_docker"
        "CONFIG_PACKAGE_dockerd"
        "CONFIG_PACKAGE_luci-app-dockerman"
        "CONFIG_PACKAGE_luci-app-amlogic"
    )
    for opt in "${check_list[@]}"; do
        grep -q "^${opt}=y" .config || missing+=("$opt")
    done

    # 软件包存在性校验（缺失的包会被 defconfig 丢弃）
    local pkg_missing=()
    for pkg in "${SELECTED_PACKAGES[@]}"; do
        grep -q "^CONFIG_PACKAGE_${pkg}=y" .config || pkg_missing+=("$pkg")
    done

    if [ ${#missing[@]} -gt 0 ]; then
        warn "以下关键系统项未被 .config 接受："
        printf '  - %s\n' "${missing[@]}" >&2
    fi
    if [ ${#pkg_missing[@]} -gt 0 ]; then
        warn "以下软件包未被 .config 接受（可能 Kconfig 中不存在）："
        printf '  - %s\n' "${pkg_missing[@]}" >&2
    fi

    log "[OK] defconfig 完成"
    log "    .config 行数: $(wc -l < .config)"
}

# =============================================================
# 7. 下载软件包源码
# =============================================================
step_download() {
    log "===== 7. 下载软件包源码 ====="
    cd "$FRIENDLYWRT_DIR"

    if [ -d "dl/go-mod-cache" ]; then
        log "清理 dl/go-mod-cache（避免跨 run 缓存污染）"
        rm -rf dl/go-mod-cache
    fi

    log "下载中（第一次）..."
    make download -j"$(nproc)" > /tmp/dl1.log 2>&1 || true

    # 清理 <1KB 的残片，然后重试
    find dl -type f -size -1024c -delete 2>/dev/null || true

    log "下载中（第二次，补偿失败项）..."
    make download -j"$(nproc)" > /tmp/dl2.log 2>&1 || true

    log "[OK] dl: $(find dl -type f | wc -l) 文件, $(du -sh dl | awk '{print $1}')"
}

# =============================================================
# 8. 全量构建（单次 make，不分阶段）
# =============================================================
step_build() {
    log "===== 8. 全量构建 ====="
    cd "$FRIENDLYWRT_DIR"

    local LOG="/tmp/build.log"
    local rc=0

    set +e
    make -j"$(nproc)" > "$LOG" 2>&1
    rc=$?
    set -e

    if [ "$rc" -ne 0 ]; then
        extract_error_context "$LOG"
        err "构建失败（详见 $LOG）"
    fi

    log "=== 构建完成 ==="
    ls -lh bin/targets/rockchip/armv8/*.img.gz 2>/dev/null \
        || ls -lh bin/targets/rockchip/armv8/ 2>/dev/null \
        || echo "(未找到镜像)"
}

# =============================================================
# 错误上下文提取（替代 tail）
# =============================================================
extract_error_context() {
    local log="$1"
    [ -f "$log" ] || return 0

    local target
    target=$(grep -nE "ERROR: (package|target|toolchain|tool)/[^ ]+ failed" "$log" \
             | head -1 | cut -d: -f1)

    if [ -z "$target" ]; then
        target=$(grep -nE "make(\[[0-9]+\])?: \*\*\* " "$log" | head -1 | cut -d: -f1)
    fi

    if [ -z "$target" ]; then
        warn "未能在日志中定位 ERROR，输出最后 120 行："
        tail -120 "$log" >&2
        return 0
    fi

    local start=$(( target > 200 ? target - 200 : 1 ))
    local end=$(( target + 30 ))

    warn "===== 错误上下文（$log 第 $start-$end 行）====="
    sed -n "${start},${end}p" "$log" >&2
    warn "===== 上下文结束 ====="
}

# =============================================================
# 主入口
# =============================================================
main() {
    log "========================================"
    log "ImmortalWrt R5S 编译脚本启动（重构版）"
    log "REPO_ROOT=$REPO_ROOT"
    log "FRIENDLYWRT_DIR=$FRIENDLYWRT_DIR"
    log "ROOTFS_PARTSIZE=$ROOTFS_PARTSIZE"
    log "CCACHE_DIR=$CCACHE_DIR"
    log "========================================"

    step_setup_ccache_and_staging
    step_verify_kernel
    step_prepare_feeds
    step_write_base_config
    step_apply_config
    step_defconfig
    step_download
    step_build

    log "========================================"
    log "全部步骤完成"
    log "========================================"
}

main "$@"