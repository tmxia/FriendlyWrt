#!/usr/bin/env bash
# ImmortalWrt NanoPi R5S 编译脚本
#
# 关键事实：
#   1. make oldconfig 只更新 .config，不会生成 include/config/auto.conf
#   2. auto.conf 由 make 目标 "include/config/auto.conf" 生成（Makefile 文件规则）
#   3. oldconfig 会重置顶层符号（CONFIG_CCACHE 等），需要用 scripts/config 恢复
#   4. 编译前 .config 与 auto.conf 必须严格同步

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PROJECT_DIR="$REPO_ROOT/project"
FRIENDLYWRT_DIR="$PROJECT_DIR/friendlywrt"
SCRIPTS_DIR="$SCRIPT_DIR"

: "${ROOTFS_PARTSIZE:=1024}"
: "${CCACHE_DIR:=$HOME/.ccache}"
: "${CCACHE_MAXSIZE:=3G}"

log()  { echo "[$(date +%H:%M:%S)] $*"; }
warn() { echo "[$(date +%H:%M:%S)] WARN: $*" >&2; }
err()  { echo "[$(date +%H:%M:%S)] ERROR: $*" >&2; exit 1; }

[ -d "$FRIENDLYWRT_DIR" ] || err "friendlywrt 源码目录不存在: $FRIENDLYWRT_DIR"

# ---------- 1. ccache + staging_dir ----------
step_setup_ccache_and_staging() {
    log "===== 1. ccache 初始化 + staging_dir 验证 ====="
    mkdir -p "$CCACHE_DIR"
    ccache --max-size="$CCACHE_MAXSIZE"
    ccache --set-config=compression=true
    ccache --set-config=compiler_check=mtime
    ccache --set-config=cache_dir="$CCACHE_DIR"
    ccache -s || true

    local STAGING="$FRIENDLYWRT_DIR/staging_dir"
    [ -d "$STAGING" ] || { log "[INFO] staging_dir 不存在（首次编译）"; return 0; }
    du -sh "$STAGING" 2>/dev/null || true

    local HOST_GCC TOOLCHAIN_DIR TC_GCC
    HOST_GCC=$(find "$STAGING/host/bin" -maxdepth 1 \( -name "gcc" -o -name "*-gcc" -o -name "gcc-*" \) 2>/dev/null | head -1)
    TOOLCHAIN_DIR=$(find "$STAGING" -maxdepth 1 -type d -name "toolchain-*" 2>/dev/null | head -1)
    [ -n "$TOOLCHAIN_DIR" ] && TC_GCC=$(find "$TOOLCHAIN_DIR/bin" -maxdepth 1 \( -name "*-gcc" -o -name "*-gcc-*" \) 2>/dev/null | head -1)

    if [ -z "$HOST_GCC" ] || [ -z "$TOOLCHAIN_DIR" ] || [ -z "$TC_GCC" ]; then
        warn "staging_dir 缓存不完整，清除重建"
        rm -rf "$STAGING"
    else
        log "[OK] staging_dir 缓存完整"
    fi
}

# ---------- 2. 内核验证 ----------
step_verify_kernel() {
    log "===== 2. 验证 6.12 内核产物 ====="
    cd "$FRIENDLYWRT_DIR"
    [ -d "target/linux/rockchip/patches-6.12" ]      || err "6.12 内核补丁目录不存在"
    [ -f "target/linux/rockchip/armv8/config-6.12" ] || err "6.12 内核配置文件不存在"
    local KVER_FILE="target/linux/generic/kernel-6.12"
    [ -f "$KVER_FILE" ] || err "内核版本文件不存在"
    local VP
    VP=$(grep -oE "^LINUX_VERSION-6\.12 = \.[0-9]+" "$KVER_FILE" | head -1 | awk '{print $3}')
    [ -n "$VP" ] || err "无法解析内核版本"
    log "[INFO] 内核版本: 6.12${VP}"
}

# ---------- 3. 初始化 .config ----------
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
    yes "" 2>/dev/null | make oldconfig > /dev/null 2>&1 || true
    log "[OK] .config 初始化完成"
}

# ---------- 4. 自定义配置 ----------
step_apply_customizations() {
    log "===== 4. 应用自定义配置 ====="
    cd "$FRIENDLYWRT_DIR"

    rm -rf package/luci-app-amlogic
    git clone --depth 1 -b main https://github.com/ophub/luci-app-amlogic.git package/luci-app-amlogic
    [ -d "package/luci-app-amlogic" ] || err "luci-app-amlogic 克隆失败"

    local add_pkgs="$SCRIPTS_DIR/add_packages.sh"
    if [ -f "$add_pkgs" ]; then
        sed -i 's|KERNEL_CONFIG_FILE="target/linux/rockchip/config-\${KERNEL_VERSION}"|KERNEL_CONFIG_FILE="target/linux/rockchip/armv8/config-\${KERNEL_VERSION}"|' "$add_pkgs"
        (cd "$PROJECT_DIR" && bash "$add_pkgs")
        log "[OK] add_packages.sh 执行完成"
    fi
}

# ---------- 5. 去重 ----------
step_dedupe_config() {
    log "===== 5. .config 去重 ====="
    cd "$FRIENDLYWRT_DIR"
    local before
    before=$(wc -l < .config)
    awk -F= '
      /^# / { print; next }
      /^CONFIG_/ { key=$1; if (!(key in seen)) { keys[++n]=key; seen[key]=1 }; values[key]=$0; next }
      { print }
      END { for (i=1;i<=n;i++) print values[keys[i]] }
    ' .config > .config.dedup && mv .config.dedup .config
    log "[OK] 去重: $before 行 → $(wc -l < .config) 行"
}

# ---------- 6. 修补 file Makefile ----------
step_patch_file_makefile() {
    log "===== 6. 修补 file Makefile 依赖 ====="
    cd "$FRIENDLYWRT_DIR"

    local FILE_MK="feeds/packages/libs/file/Makefile"
    [ -f "$FILE_MK" ] || { warn "$FILE_MK 不存在，跳过"; return 0; }

    python3 - "$FILE_MK" <<'PY'
import re, sys, pathlib
p = pathlib.Path(sys.argv[1]); txt = p.read_text()
m = re.search(r'(define Package/libmagic\b.*?DEPENDS:=)([^\n]*)', txt, flags=re.S)
if not m: print("PATTERN NOT FOUND"); sys.exit(0)
deps = m.group(2); added = []
for r in ['+libbz2', '+liblzma']:
    if r not in deps: deps += " " + r; added.append(r)
if added:
    p.write_text(txt[:m.start(2)] + deps + txt[m.end(2):])
    print(f"PATCHED: {added}")
else:
    print("No change")
PY
    log "[OK] file Makefile 依赖已修补"
}

# ---------- 关键配置写入 ----------
apply_critical_cfg() {
    cd "$FRIENDLYWRT_DIR"
    local CFG="scripts/config/Config"

    if [ -x "$CFG" ]; then
        local pkg
        for pkg in docker dockerd docker-compose luci-app-dockerman \
                   luci-i18n-dockerman-zh-cn luci-lib-docker luci-app-amlogic; do
            "$CFG" --enable "PACKAGE_${pkg}" 2>/dev/null || true
        done
        "$CFG" --enable  CCACHE
        "$CFG" --set-str CCACHE_DIR "$CCACHE_DIR"
        "$CFG" --set-val TARGET_ROOTFS_PARTSIZE "$ROOTFS_PARTSIZE"
        "$CFG" --enable  LINUX_6_12
        "$CFG" --enable  PCIE_ROCKCHIP_DW_HOST
        "$CFG" --enable  PHY_ROCKCHIP_NANENG_COMBPHY
        "$CFG" --enable  DOCKER_KERNEL_OPTIONS
        "$CFG" --enable  DOCKER_NET_OVERLAY
    else
        local pkg
        for pkg in docker dockerd docker-compose luci-app-dockerman \
                   luci-i18n-dockerman-zh-cn luci-lib-docker luci-app-amlogic; do
            sed -i "/^# CONFIG_PACKAGE_${pkg} is not set/d" .config 2>/dev/null || true
            sed -i "/^CONFIG_PACKAGE_${pkg}=/d" .config
            echo "CONFIG_PACKAGE_${pkg}=y" >> .config
        done
        local kv
        while IFS= read -r line; do
            [ -z "$line" ] && continue
            kv="${line%%=*}"
            sed -i "/^${kv}=/d" .config
            sed -i "/^# ${kv} is not set/d" .config
            echo "$line" >> .config
        done <<EOF
CONFIG_CCACHE=y
CONFIG_CCACHE_DIR="$CCACHE_DIR"
CONFIG_TARGET_ROOTFS_PARTSIZE=$ROOTFS_PARTSIZE
CONFIG_LINUX_6_12=y
CONFIG_PCIE_ROCKCHIP_DW_HOST=y
CONFIG_PHY_ROCKCHIP_NANENG_COMBPHY=y
CONFIG_DOCKER_KERNEL_OPTIONS=y
CONFIG_DOCKER_NET_OVERLAY=y
EOF
    fi
}

# ---------- 7. 强制修正 + 显式生成 auto.conf ----------
step_force_config() {
    log "===== 7. 强制修正关键配置 + 生成 auto.conf ====="
    cd "$FRIENDLYWRT_DIR"

    # 1) 用 scripts/config 写入关键配置
    apply_critical_cfg

    # 2) 清除缓存强制重算依赖图
    rm -f tmp/.config-package.in tmp/.packageinfo tmp/.targetinfo

    # 3) oldconfig 重建 tmp/
    log "运行 oldconfig（重建依赖图）..."
    yes "" 2>/dev/null | make oldconfig > /dev/null 2>&1 || true

    # 4) 恢复 oldconfig 可能重置的顶层符号
    log "修正 oldconfig 可能重置的顶层符号..."
    apply_critical_cfg

    # 5) oldconfig 把 .config 规范化
    log "运行 oldconfig（规范化 .config）..."
    yes "" 2>/dev/null | make oldconfig > /dev/null 2>&1 || true

    # ============================================================
    # 【核心修复】
    # make oldconfig 不会生成 include/config/auto.conf。
    # auto.conf 由 Makefile 中的文件规则生成，必须显式调用该目标。
    # ============================================================
    log "显式生成 include/config/auto.conf..."
    make -s include/config/auto.conf 2>&1 | tail -3 || true

    if [ ! -f include/config/auto.conf ]; then
        warn "首次生成 auto.conf 失败，尝试 make prepare-tmpinfo..."
        make -s prepare-tmpinfo 2>&1 | tail -3 || true
        make -s include/config/auto.conf 2>&1 | tail -3 || true
    fi

    if [ ! -f include/config/auto.conf ]; then
        err "无法生成 include/config/auto.conf（OpenWrt 构建系统异常）"
    fi

    # 6) 校验关键符号：.config 与 auto.conf 必须同时包含
    log "校验 .config 与 include/config/auto.conf 一致性..."
    local checks=(
        "^CONFIG_CCACHE=y"
        "^CONFIG_TARGET_ROOTFS_PARTSIZE=$ROOTFS_PARTSIZE"
        "^CONFIG_LINUX_6_12=y"
        "^CONFIG_PCIE_ROCKCHIP_DW_HOST=y"
        "^CONFIG_PHY_ROCKCHIP_NANENG_COMBPHY=y"
        "^CONFIG_PACKAGE_docker=y"
        "^CONFIG_PACKAGE_dockerd=y"
        "^CONFIG_PACKAGE_docker-compose=y"
        "^CONFIG_PACKAGE_luci-app-dockerman=y"
        "^CONFIG_PACKAGE_luci-i18n-dockerman-zh-cn=y"
        "^CONFIG_PACKAGE_luci-lib-docker=y"
        "^CONFIG_PACKAGE_luci-app-amlogic=y"
        "^CONFIG_DOCKER_KERNEL_OPTIONS=y"
        "^CONFIG_DOCKER_NET_OVERLAY=y"
    )
    local pat
    for pat in "${checks[@]}"; do
        grep -qE "$pat" .config || err "关键配置缺失: $pat"
        grep -qE "$pat" include/config/auto.conf || err "auto.conf 未同步: $pat"
    done

    # 7) mtime 检查：auto.conf 必须不早于 .config
    if [ include/config/auto.conf -ot .config ]; then
        warn "auto.conf 比 .config 旧，touch 修正 mtime"
        touch include/config/auto.conf
    fi

    log "[OK] 配置与依赖图已严格同步"
    grep -E "^CONFIG_(CCACHE|TARGET_ROOTFS_PARTSIZE|LINUX_6|PCIE_ROCKCHIP|PHY_ROCKCHIP|PACKAGE_docker|PACKAGE_dockerd|PACKAGE_luci-app-dockerman|PACKAGE_luci-app-amlogic|DOCKER_)" .config
}

# ---------- 8. 下载源码 ----------
step_download_packages() {
    log "===== 8. 下载软件包源码 ====="
    cd "$FRIENDLYWRT_DIR"
    [ -d "dl/go-mod-cache" ] && rm -rf dl/go-mod-cache

    make download -j"$(nproc)" > /tmp/dl1.log 2>&1 || true
    find dl -type f -size -1024c -delete 2>/dev/null || true
    make download -j"$(nproc)" > /tmp/dl2.log 2>&1 || true
    log "[OK] dl: $(find dl -type f | wc -l) 文件"
}

# ---------- 9. 编译 ----------
step_compile() {
    log "===== 9. 编译 ====="
    cd "$FRIENDLYWRT_DIR"

    # 编译前最终确认 auto.conf 与 .config 一致（只读检查）
    if [ ! -f include/config/auto.conf ]; then
        warn "auto.conf 在编译前缺失，重新生成"
        make -s include/config/auto.conf > /dev/null 2>&1 || true
    fi

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
        tail -120 "$LOG"
        err "final make 失败"
    fi
    log "[DONE] final make"
    log "=== OpenWrt 编译完成 ==="
    ls -lh bin/targets/rockchip/armv8/*.img.gz 2>/dev/null || echo "(未找到原生镜像)"
}

# ---------- main ----------
main() {
    log "========================================"
    log "ImmortalWrt R5S 编译脚本启动"
    log "ROOTFS_PARTSIZE=$ROOTFS_PARTSIZE  CCACHE_DIR=$CCACHE_DIR"
    log "========================================"

    step_setup_ccache_and_staging
    step_verify_kernel
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