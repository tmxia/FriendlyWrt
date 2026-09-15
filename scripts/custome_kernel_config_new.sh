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

log()  { echo "[$(date +%H:%M:%S)] $*"; }
warn() { echo "[$(date +%H:%M:%S)] WARN: $*" >&2; }
err()  { echo "[$(date +%H:%M:%S)] ERROR: $*" >&2; exit 1; }

[ -d "$FRIENDLYWRT_DIR" ] || err "friendlywrt 源码目录不存在"
[ -f "$SCRIPTS_DIR/add_packages.sh" ] || err "add_packages.sh 不存在"

step_ccache_and_staging() {
    log "===== 1. ccache + staging_dir 验证 ====="

    mkdir -p "$CCACHE_DIR"
    ccache --max-size="$CCACHE_MAXSIZE"
    ccache --set-config=compression=true
    ccache --set-config=compiler_check=mtime
    ccache --set-config=cache_dir="$CCACHE_DIR"
    ccache -s

    local STAGING="$FRIENDLYWRT_DIR/staging_dir"
    [ -d "$STAGING" ] || { log "staging_dir 不存在（首次编译）"; return; }

    local HOST_GCC TC_GCC
    HOST_GCC=$(find "$STAGING/host/bin" -maxdepth 1 -name "*-gcc*" 2>/dev/null | head -1)
    TC_GCC=$(find "$STAGING"/toolchain-*/bin -maxdepth 1 -name "*-gcc" 2>/dev/null | head -1)

    if [ -z "$HOST_GCC" ] || [ -z "$TC_GCC" ]; then
        warn "staging_dir 缓存不完整，删除"
        rm -rf "$STAGING"
    else
        log "[OK] staging_dir 完整"
    fi
}

step_verify_kernel() {
    log "===== 2. 探测内核产物 ====="
    cd "$FRIENDLYWRT_DIR"

    local KVER
    KVER=$(grep -E "^KERNEL_PATCHVER" target/linux/rockchip/Makefile | sed 's/.*[:=]//' | tr -d ' \t')
    log "KERNEL_PATCHVER=${KVER}"

    find target/linux/rockchip -maxdepth 3 \( -type d -name "patches-*" -o -type f -name "config-*" \) 2>/dev/null
}

# add_packages.sh 硬编码 config-6.1 路径，通过软链指向真实 6.12 配置
step_bridge_kernel_config() {
    log "===== 3. 桥接 config-6.1 -> config-6.12 ====="
    cd "$FRIENDLYWRT_DIR/target/linux/rockchip" || return

    [ -f armv8/config-6.12 ] || err "找不到 armv8/config-6.12"
    [ -e config-6.1 ] || ln -s armv8/config-6.12 config-6.1
    ls -la config-6.1
}

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

    yes "" | make oldconfig > /dev/null 2>&1
    log "[OK] .config 初始化完成"
}

step_apply_customizations() {
    log "===== 5. 应用自定义配置 ====="

    # luci-app-amlogic 不在 feeds 中，需手动克隆到 package/
    log "克隆 luci-app-amlogic..."
    rm -rf "$FRIENDLYWRT_DIR/package/luci-app-amlogic"
    git clone --depth 1 -b main \
        https://github.com/ophub/luci-app-amlogic.git \
        "$FRIENDLYWRT_DIR/package/luci-app-amlogic" 2>&1 | tail -1

    # 克隆后刷新包索引，使 CONFIG_PACKAGE_luci-app-amlogic 可被识别
    cd "$FRIENDLYWRT_DIR"
    make defconfig > /dev/null 2>&1
    sed -i '/^# CONFIG_PACKAGE_luci-app-amlogic is not set/d' .config
    sed -i '/^CONFIG_PACKAGE_luci-app-amlogic=/d' .config
    echo "CONFIG_PACKAGE_luci-app-amlogic=y" >> .config
    yes "" | make oldconfig > /dev/null 2>&1

    # 修正 add_packages.sh 里硬编码的 kernel config 路径
    sed -i 's|target/linux/rockchip/config-\${KERNEL_VERSION}|target/linux/rockchip/armv8/config-\${KERNEL_VERSION}|' \
        "$SCRIPTS_DIR/add_packages.sh"

    cd "$PROJECT_DIR"
    bash "$SCRIPTS_DIR/add_packages.sh"
    log "[OK] add_packages.sh 执行完成"
}

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

step_patch_file_makefile() {
    log "===== 7. 修补 file Makefile ====="
    cd "$FRIENDLYWRT_DIR"

    local FILE_MK="feeds/packages/libs/file/Makefile"
    [ -f "$FILE_MK" ] || { log "跳过（$FILE_MK 不存在）"; return; }

    # libmagic 依赖 libbz2/liblzma，需补上
    python3 - "$FILE_MK" <<'PY'
import re, sys, pathlib
p = pathlib.Path(sys.argv[1])
txt = p.read_text()
m = re.search(r'(define Package/libmagic\b.*?DEPENDS:=)([^\n]*)', txt, flags=re.S)
if not m: sys.exit(0)
deps = m.group(2)
if '+libbz2' not in deps or '+liblzma' not in deps:
    deps += " +libbz2 +liblzma"
    p.write_text(txt[:m.start(2)] + deps + txt[m.end(2):])
PY

    for sym in PACKAGE_libbz2 PACKAGE_liblzma PACKAGE_zlib; do
        sed -i "/^# CONFIG_${sym} is not set/d; /^CONFIG_${sym}=/d" .config
        echo "CONFIG_${sym}=y" >> .config
    done
    yes "" | make oldconfig > /dev/null 2>&1
    log "[OK] file Makefile 已修补"
}

step_force_config() {
    log "===== 8. 强制修正关键配置 ====="
    cd "$FRIENDLYWRT_DIR"

    sed -i '/^CONFIG_CCACHE_DIR=/d' .config
    echo "CONFIG_CCACHE_DIR=\"$CCACHE_DIR\"" >> .config
    sed -i '/^CONFIG_CCACHE=/d' .config
    echo "CONFIG_CCACHE=y" >> .config
    sed -i '/^CONFIG_TARGET_ROOTFS_PARTSIZE=/d' .config
    echo "CONFIG_TARGET_ROOTFS_PARTSIZE=$ROOTFS_PARTSIZE" >> .config

    local pkg
    for pkg in docker dockerd docker-compose luci-app-dockerman luci-i18n-dockerman-zh-cn luci-lib-docker \
               luci-app-amlogic luci-lib-nixio block-mount blkid parted dosfstools e2fsprogs jq lsblk pv losetup uuidgen bash perl fdisk; do
        sed -i "/^CONFIG_PACKAGE_${pkg}=/d" .config
        echo "CONFIG_PACKAGE_${pkg}=y" >> .config
    done

    log "[OK] 关键配置已强制修正"
}

step_download_packages() {
    log "===== 9. 下载软件包源码 ====="
    cd "$FRIENDLYWRT_DIR"
    rm -rf dl/go-mod-cache

    make download -j"$(nproc)" > /dev/null 2>&1 || true
    find dl -type f -size -1024c -delete 2>/dev/null || true
    make download -j"$(nproc)" > /dev/null 2>&1 || true
    log "[OK] dl: $(find dl -type f | wc -l) 文件"
}

step_compile() {
    log "===== 10. 分阶段编译 ====="
    cd "$FRIENDLYWRT_DIR"

    local s
    for s in tools/compile toolchain/compile target/compile package/compile; do
        log "---- STAGE: $s ----"
        make -j"$(nproc)" "$s" > "/tmp/build_${s//\//_}.log" 2>&1 \
            || { tail -100 "/tmp/build_${s//\//_}.log"; err "编译失败: $s"; }
        log "[DONE] $s"
    done

    log "---- STAGE: final make ----"
    make -j"$(nproc)" > /tmp/build_final.log 2>&1 \
        || { tail -100 /tmp/build_final.log; err "final make 失败"; }
    log "[DONE] final make"

    ls -lh bin/targets/rockchip/armv8/*.img.gz
}

main() {
    log "ImmortalWrt R5S 编译脚本启动"

    step_ccache_and_staging
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