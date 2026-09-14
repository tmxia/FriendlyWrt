#!/usr/bin/env bash
# =============================================================
# custome_kernel_config_new.sh
# FriendlyWrt NanoPi R5S 编译主脚本
#
# 用途：
#   GitHub Actions 只需调用此脚本一次，脚本内部完成：
#     环境准备 → 配置 → 编译 → 诊断 → 打包 → 产物命名
#
# 环境变量（可选）：
#   ROOTFS_PARTSIZE   根分区大小，默认 1024
#   CCACHE_DIR        ccache 目录，默认 $HOME/.ccache
#   CCACHE_MAXSIZE    ccache 上限，默认 3G
#   TARGET_OS         打包目标名，默认 friendlywrt25
#   MODEL_NAME        产物机型名，默认 R5S-R5C-Series
#   FRIENDLY_VER      版本号，默认 25.12
# =============================================================

set -e

# ---------- 路径与环境 ----------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
FW="$REPO_ROOT/project/friendlywrt"
ART="$REPO_ROOT/artifact"

: "${ROOTFS_PARTSIZE:=1024}"
: "${CCACHE_DIR:=$HOME/.ccache}"
: "${CCACHE_MAXSIZE:=3G}"
: "${TARGET_OS:=friendlywrt25}"
: "${MODEL_NAME:=R5S-R5C-Series}"
: "${FRIENDLY_VER:=25.12}"

log()  { echo "[$(date +%H:%M:%S)] $*"; }
warn() { echo "[$(date +%H:%M:%S)] WARN: $*" >&2; }
err()  { echo "[$(date +%H:%M:%S)] ERROR: $*" >&2; exit 1; }

# =============================================================
#  1. 准备源码（feeds）
# =============================================================
prepare_workspace() {
    log "===== 1. 准备源码 ====="
    cd "$FW"
    ./scripts/feeds update -a > /dev/null 2>&1 || ./scripts/feeds update -a
    ./scripts/feeds install -a > /dev/null 2>&1
    mkdir -p "$REPO_ROOT/project/configs/rockchip"
    touch "$REPO_ROOT/project/configs/rockchip/01-nanopi"
    log "[OK] feeds 就绪"
}

# =============================================================
#  2. ccache + staging_dir 完整性验证
# =============================================================
setup_ccache() {
    log "===== 2. ccache + staging_dir ====="
    mkdir -p "$CCACHE_DIR"
    ccache --max-size="$CCACHE_MAXSIZE"
    ccache --set-config=compression=true
    ccache --set-config=compiler_check=mtime
    ccache --set-config=cache_dir="$CCACHE_DIR"
    ccache -s || true

    local STAGING="$FW/staging_dir"
    [ ! -d "$STAGING" ] && { log "[INFO] staging_dir 不存在（首次编译）"; return 0; }

    local HOST_GCC TOOLCHAIN_DIR TC_GCC
    HOST_GCC=$(find "$STAGING/host/bin" -maxdepth 1 -name "*-gcc*" 2>/dev/null | head -1)
    TOOLCHAIN_DIR=$(find "$STAGING" -maxdepth 1 -type d -name "toolchain-*" 2>/dev/null | head -1)
    TC_GCC=""
    [ -n "$TOOLCHAIN_DIR" ] && TC_GCC=$(find "$TOOLCHAIN_DIR/bin" -maxdepth 1 -name "*-gcc" 2>/dev/null | head -1)

    if [ -z "$HOST_GCC" ] || [ -z "$TC_GCC" ]; then
        warn "staging_dir 缓存不完整，清除并重新编译"
        rm -rf "$STAGING"
    else
        log "[OK] staging_dir 缓存完整（$(du -sh "$STAGING" | awk '{print $1}')）"
    fi
}

# =============================================================
#  3. 内核产物验证 + config-6.1 桥接
# =============================================================
prepare_kernel() {
    log "===== 3. 内核准备 ====="
    cd "$FW"
    [ -d target/linux/rockchip/patches-6.12 ] && [ -f target/linux/rockchip/armv8/config-6.12 ] \
        || err "6.12 内核产物不存在"
    cd target/linux/rockchip
    [ -e config-6.1 ] || ln -s armv8/config-6.12 config-6.1
    log "[OK] 内核产物就绪"
}

# =============================================================
#  4. 初始化 .config
# =============================================================
init_config() {
    log "===== 4. 初始化 .config ====="
    cd "$FW"
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
EOF
    yes "" 2>/dev/null | make oldconfig > /dev/null 2>&1 || make defconfig > /dev/null 2>&1
    log "[OK] .config 初始化"
}

# =============================================================
#  5. 自定义（修复 add_packages.sh + 执行 + 去重 + patch）
# =============================================================
apply_customizations() {
    log "===== 5. 应用自定义 ====="
    cd "$FW"

    # 修复 add_packages.sh 内核路径 bug
    local add_pkgs="$SCRIPT_DIR/add_packages.sh"
    [ -f "$add_pkgs" ] && sed -i \
        's|KERNEL_CONFIG_FILE="target/linux/rockchip/config-\${KERNEL_VERSION}"|KERNEL_CONFIG_FILE="target/linux/rockchip/armv8/config-\${KERNEL_VERSION}"|' \
        "$add_pkgs"

    cd "$REPO_ROOT/project"
    bash "$add_pkgs"

    cd "$FW"

    # .config 去重
    local before after
    before=$(wc -l < .config)
    awk -F= '
      /^# / { print; next }
      /^CONFIG_/ { key=$1; if(!(key in s)){k[++n]=key;s[key]=1} v[key]=$0; next }
      { print }
      END { for(i=1;i<=n;i++) print v[k[i]] }
    ' .config > .config.dedup && mv .config.dedup .config
    after=$(wc -l < .config)
    log "[OK] .config 去重: $before → $after 行"

    # 修补 file Makefile
    local FILE_MK="feeds/packages/libs/file/Makefile"
    [ -f "$FILE_MK" ] || err "$FILE_MK 不存在"

    yes "" 2>/dev/null | make oldconfig > /dev/null 2>&1 || make defconfig > /dev/null 2>&1 || true

    python3 - "$FILE_MK" <<'PY'
import re, sys, pathlib
p = pathlib.Path(sys.argv[1])
txt = p.read_text()
m = re.search(r'(define Package/libmagic\b.*?DEPENDS:=)([^\n]*)', txt, flags=re.S)
if m:
    deps = m.group(2); added = []
    for r in ['+libbz2', '+liblzma']:
        if r not in deps: deps += " " + r; added.append(r)
    if added:
        p.write_text(txt[:m.start(2)] + deps + txt[m.end(2):])
        print(f"PATCHED: {added}")
PY

    local SYMS="PACKAGE_libbz2 PACKAGE_liblzma PACKAGE_zlib" hint found
    for hint in libbz2 liblzma zlib; do
        found=$(grep -oE "config PACKAGE_${hint}[-0-9._]*" tmp/.config-package.in 2>/dev/null \
                    | awk '{print $2}' | sort -u || true)
        SYMS="$SYMS $found"
    done
    for sym in $SYMS; do
        [ -z "$sym" ] && continue
        sed -i "/^# CONFIG_${sym} is not set/d" .config
        sed -i "/^CONFIG_${sym}=/d" .config
        echo "CONFIG_${sym}=y" >> .config
    done
    yes "" 2>/dev/null | make oldconfig > /dev/null 2>&1 || make defconfig > /dev/null 2>&1
    log "[OK] file Makefile 依赖修补"
}

# =============================================================
#  6. 强制修正关键配置
# =============================================================
force_config() {
    log "===== 6. 强制修正关键配置 ====="
    cd "$FW"
    sed -i '/^CONFIG_CCACHE_DIR=/d;/^# CONFIG_CCACHE_DIR is not set/d' .config
    echo "CONFIG_CCACHE_DIR=\"$CCACHE_DIR\"" >> .config
    sed -i '/^CONFIG_CCACHE=/d;/^# CONFIG_CCACHE is not set/d' .config
    echo "CONFIG_CCACHE=y" >> .config
    sed -i '/^CONFIG_TARGET_ROOTFS_PARTSIZE=/d;/^# CONFIG_TARGET_ROOTFS_PARTSIZE is not set/d' .config
    echo "CONFIG_TARGET_ROOTFS_PARTSIZE=$ROOTFS_PARTSIZE" >> .config

    local pkg
    for pkg in docker dockerd docker-compose luci-app-dockerman luci-i18n-dockerman-zh-cn luci-lib-docker; do
        sed -i "/^CONFIG_PACKAGE_${pkg}=/d;/^# CONFIG_PACKAGE_${pkg} is not set/d" .config
        echo "CONFIG_PACKAGE_${pkg}=y" >> .config
    done
    sed -i '/^CONFIG_DOCKER_KERNEL_OPTIONS=/d' .config
    echo "CONFIG_DOCKER_KERNEL_OPTIONS=y" >> .config
    sed -i '/^CONFIG_DOCKER_NET_OVERLAY=/d' .config
    echo "CONFIG_DOCKER_NET_OVERLAY=y" >> .config
    log "[OK]"
}

# =============================================================
#  编译期：恢复配置
# =============================================================
restore_cfg() {
    cd "$FW"
    local s=false
    grep -q "^CONFIG_CCACHE_DIR=\"$CCACHE_DIR\"" .config || {
        sed -i '/^CONFIG_CCACHE_DIR=/d;/^# CONFIG_CCACHE_DIR is not set/d' .config
        echo "CONFIG_CCACHE_DIR=\"$CCACHE_DIR\"" >> .config; s=true; }
    grep -q "^CONFIG_CCACHE=y" .config || { echo "CONFIG_CCACHE=y" >> .config; s=true; }
    grep -q "^CONFIG_TARGET_ROOTFS_PARTSIZE=$ROOTFS_PARTSIZE" .config || {
        sed -i '/^CONFIG_TARGET_ROOTFS_PARTSIZE=/d' .config
        echo "CONFIG_TARGET_ROOTFS_PARTSIZE=$ROOTFS_PARTSIZE" >> .config; s=true; }
    local pkg
    for pkg in docker dockerd docker-compose luci-app-dockerman luci-i18n-dockerman-zh-cn luci-lib-docker; do
        grep -q "^CONFIG_PACKAGE_${pkg}=y" .config || {
            sed -i "/^CONFIG_PACKAGE_${pkg}=/d;/^# CONFIG_PACKAGE_${pkg} is not set/d" .config
            echo "CONFIG_PACKAGE_${pkg}=y" >> .config; s=true; }
    done
    grep -q "^CONFIG_DOCKER_KERNEL_OPTIONS=y" .config || {
        echo "CONFIG_DOCKER_KERNEL_OPTIONS=y" >> .config; s=true; }
    [ "$s" = "true" ] && log "[CFG] 已恢复"
    return 0
}

# =============================================================
#  7. 下载 + 编译 + 诊断
# =============================================================
download_and_compile() {
    log "===== 7. 下载 + 编译 ====="
    cd "$FW"

    make download -j"$(nproc)" > /tmp/dl1.log 2>&1 || true
    find dl -type f -size -1024c -delete 2>/dev/null || true
    make download -j"$(nproc)" > /tmp/dl2.log 2>&1 || true
    log "[OK] dl: $(find dl -type f | wc -l) 文件, $(du -sh dl | awk '{print $1}')"

    restore_cfg > /dev/null 2>&1

    local s LOG FAILED
    for s in tools/compile toolchain/compile target/compile package/compile; do
        log "---- STAGE: $s ----"
        restore_cfg > /dev/null 2>&1
        LOG="/tmp/build_$(echo "$s" | tr '/' '_').log"
        if ! make -j"$(nproc)" "$s" > "$LOG" 2>&1; then
            warn "STAGE FAILED: $s"
            tail -80 "$LOG"
            FAILED=$(grep -oE "ERROR: package/[^ ]+ failed to build" "$LOG" | head -1 | awk '{print $2}')
            [ -n "$FAILED" ] && make -j1 V=s "$FAILED/compile" 2>&1 | tail -150 || true
            err "编译失败: $s"
        fi
        log "[DONE] $s"
    done

    # final make
    log "---- STAGE: final make ----"
    restore_cfg > /dev/null 2>&1
    LOG="/tmp/build_final.log"
    if make -j"$(nproc)" > "$LOG" 2>&1; then
        log "[DONE] final make"
    else
        warn "首次 final make 失败，诊断中..."
        grep -E "ERROR: (target|package|toolchain|tool)/[^ ]+ failed" "$LOG" | tail -5 || true

        # 空间不足
        if grep -qE "out of space|failed to allocate" "$LOG"; then
            local RD MB NEW
            RD=$(find build_dir/target-* -maxdepth 1 -type d -name "root-*" | head -1)
            [ -n "$RD" ] && {
                MB=$(du -s -m "$RD" | awk '{print $1}')
                NEW=$(( ((MB + 64 + 63) / 64 * 64) + 256 ))
                sed -i '/^CONFIG_TARGET_ROOTFS_PARTSIZE=/d' .config
                echo "CONFIG_TARGET_ROOTFS_PARTSIZE=$NEW" >> .config
                rm -f build_dir/target-*/linux-rockchip_armv8/root.ext4* 2>/dev/null || true
                rm -f build_dir/target-*/linux-rockchip_armv8/root.squashfs 2>/dev/null || true
                log "[FIX] rootfs 扩至 ${NEW} MB"
            }
        fi

        # target/linux 失败
        if grep -qE "ERROR: target/linux failed" "$LOG" && ! grep -qE "out of space" "$LOG"; then
            make defconfig > /dev/null 2>&1 || true
            yes "" 2>/dev/null | make oldconfig > /dev/null 2>&1 || true
            restore_cfg > /dev/null 2>&1
            make -j1 V=s target/linux/install 2>&1 | tail -100 || true
        fi

        # 特定包失败
        local FP
        FP=$(grep -oE "ERROR: package/[^ ]+ failed" "$LOG" | head -1 | sed 's|ERROR: ||; s| failed||')
        [ -n "$FP" ] && make -j1 V=s "$FP/compile" 2>&1 | tail -100 || true

        # 重试
        restore_cfg > /dev/null 2>&1
        make -j"$(nproc)" > /tmp/build_final_retry.log 2>&1 \
            || err "final make 重试失败（详见 /tmp/build_final_retry.log）"
        log "[DONE] final make (retry)"
    fi
}

# =============================================================
#  8. 打包 sd-fuse + 生成产物
# =============================================================
package() {
    log "===== 8. 打包 sd-fuse ====="
    cd "$FW"

    # 定位
    local TRIPLE KDIR IMG DTB ROOTFS KV SF
    TRIPLE=$(realpath "$(find build_dir -maxdepth 1 -type d -name 'target-*_musl' | head -1)")
    [ -z "$TRIPLE" ] && err "target triple 未找到"
    KDIR=$(realpath "$(find "$TRIPLE" -maxdepth 1 -type d -name 'linux-rockchip*' | head -1)")
    IMG=$(realpath "$(find "$KDIR" -path '*/arch/arm64/boot/Image' -type f 2>/dev/null | head -1)")
    DTB=$(realpath "$(find "$KDIR" -path '*/arch/arm64/boot/dts/rockchip' -type d 2>/dev/null | head -1)")
    ROOTFS=$(realpath "$(find "$TRIPLE" -maxdepth 1 -type d -name 'root-*' | head -1)")
    KV=$(ls "$ROOTFS/lib/modules/" 2>/dev/null | head -1)

    [ -f "$IMG" ] && [ -d "$DTB" ] && [ -d "$ROOTFS" ] || err "关键产物缺失"
    [[ "$KV" == 6.12* ]] || err "内核模块版本错误: $KV"
    log "[OK] 内核: $KV, rootfs: $(du -sh "$ROOTFS" | awk '{print $1}')"

    # Clone sd-fuse
    cd "$REPO_ROOT/project"
    rm -rf sd-fuse
    git clone --depth 1 https://github.com/friendlyarm/sd-fuse_rk3568.git sd-fuse
    SF="$PWD/sd-fuse"
    TGT="$SF/$TARGET_OS"
    mkdir -p "$TGT"

    # 打包 kernel.img
    "$SF/tools/mkkrnlimg" "$IMG" "$TGT/kernel.img"
    cp "$TGT/kernel.img" "$TGT/boot.img"
    log "[OK] kernel.img: $(ls -lh "$TGT/kernel.img" | awk '{print $5}')"

    # 打包 resource.img（resource_tool 不拼 --root，需在文件所在目录运行）
    rm -rf /tmp/dtb-pack && mkdir -p /tmp/dtb-pack
    cp "$DTB/rk3568-nanopi-r5s.dtb" /tmp/dtb-pack/rk-kernel.dtb
    [ -f "$DTB/rk3568-nanopi-r5s.dtb" ] && cp "$DTB/rk3568-nanopi-r5s.dtb" /tmp/dtb-pack/
    [ -f "$DTB/rk3568-nanopi-r5c.dtb" ] && cp "$DTB/rk3568-nanopi-r5c.dtb" /tmp/dtb-pack/
    cd /tmp/dtb-pack
    local DTB_LIST
    DTB_LIST=$(find . -maxdepth 1 -type f -name "*.dtb" -printf "%f\n" | sort)
    "$SF/tools/resource_tool" --pack --root=. --image="$TGT/resource.img" $DTB_LIST
    cd "$REPO_ROOT/project"
    log "[OK] resource.img: $(ls -lh "$TGT/resource.img" | awk '{print $5}')"

    # U-Boot
    cd "$SF"
    for f in uboot.img idbloader.img MiniLoaderAll.bin misc.img dtbo.img; do
        [ -f "prebuilt/$f" ] && cp "prebuilt/$f" "$TARGET_OS/$f"
    done

    # rootfs.img
    rm -rf /tmp/rootfs-pack
    cp -a "$ROOTFS" /tmp/rootfs-pack
    (cd /tmp/rootfs-pack/dev && find . ! -type d -exec rm -f {} \; ) 2>/dev/null || true
    local MKFS="$SF/tools/mke2fs"
    local MKFS_CONF="$SF/tools/mke2fs.conf"
    local ISZ=$(( (`du -s -B64M /tmp/rootfs-pack | cut -f1` + 3) * 1024 * 1024 * 64 ))
    local IBLK=$(( ISZ / 4096 ))
    local INO=$(( `find /tmp/rootfs-pack | wc -l` + 128 ))
    rm -f "$TGT/rootfs.img"
    MKE2FS_CONFIG="$MKFS_CONF" "$MKFS" -N "$INO" \
        -E android_sparse -t ext4 -L rootfs -M /root -b 4096 -0 \
        -d /tmp/rootfs-pack "$TGT/rootfs.img" "$IBLK"
    local RSZ
    RSZ=$(stat -c%s "$TGT/rootfs.img")
    log "[OK] rootfs.img: $(ls -lh "$TGT/rootfs.img" | awk '{print $5}')"

    # parameter.txt
    PARAMETER_TPL="$SF/prebuilt/parameter.template" \
        "$SF/tools/generate-partmap-txt.sh" "$RSZ" "$TARGET_OS"

    # SD + eMMC
    export SDFUSE_NONINTERACTIVE=y
    (cd "$SF" && sudo -E ./mk-sd-image.sh "$TARGET_OS" > /tmp/sd.log 2>&1) || warn "mk-sd-image 非零退出"
    (cd "$SF" && sudo -E ./mk-emmc-image.sh "$TARGET_OS" autostart=yes > /tmp/emmc.log 2>&1) || warn "mk-emmc-image 非零退出"

    # sudo 产物属主修复
    [ -d "$SF/out" ] && sudo chown -R "$(id -u):$(id -g)" "$SF/out" 2>/dev/null || true
    [ -d "$TGT" ] && sudo chown -R "$(id -u):$(id -g)" "$TGT" 2>/dev/null || true
    log "[OK] SD/eMMC 镜像已生成"
}

# =============================================================
#  9. 产物重命名 + SHA256 + README
# =============================================================
finalize_artifacts() {
    log "===== 9. 产物归档 ====="
    mkdir -p "$ART"
    cd "$REPO_ROOT/project/sd-fuse"

    # SD img
    local SRC
    SRC=$(find out -maxdepth 1 -name "*.img" -type f 2>/dev/null | head -1)
    if [ -n "$SRC" ] && [ -s "$SRC" ]; then
        local NAME="${MODEL_NAME}-FriendlyWrt-${FRIENDLY_VER}.img"
        cp "$SRC" "/tmp/$NAME" && gzip -f "/tmp/$NAME"
        cp "/tmp/${NAME}.gz" "$ART/"
        log "[OK] SD: ${NAME}.gz"
    else
        warn "未找到 SD .img"
    fi

    # eMMC tgz
    SRC=$(find out -maxdepth 3 -name "*-images.tgz" -type f 2>/dev/null | head -1)
    if [ -n "$SRC" ] && [ -s "$SRC" ]; then
        local NAME="images-${MODEL_NAME}-FriendlyWrt-${FRIENDLY_VER}.tgz"
        cp "$SRC" "$ART/$NAME"
        log "[OK] eMMC: $NAME"
    fi

    # OpenWrt 原生 sysupgrade
    SRC=$(find "$FW/bin/targets/rockchip/armv8" -maxdepth 1 \
        -name "*nanopi-r5s*sysupgrade.img.gz" -type f 2>/dev/null | head -1)
    [ -n "$SRC" ] && cp "$SRC" "$ART/${MODEL_NAME}-OpenWrt-${FRIENDLY_VER}-sysupgrade.img.gz"

    # manifest
    SRC=$(find "$FW/bin/targets/rockchip/armv8" -maxdepth 1 \
        -name "*nanopi-r5s*.manifest" -type f 2>/dev/null | head -1)
    [ -n "$SRC" ] && cp "$SRC" "$ART/"

    # SHA256
    cd "$ART"
    rm -f SHA256SUMS
    for f in *; do
        [ -f "$f" ] && [ "$f" != "SHA256SUMS" ] && sha256sum "$f" >> SHA256SUMS
    done

    # README
    cat > README.txt <<EOF
FriendlyWrt for NanoPi R5S — Build $(date +%Y-%m-%d)
============================================================
内核版本: 6.12 (OpenWrt 官方 openwrt-25.12 分支)
基础系统: OpenWrt 25.12 + Clashoo + Docker + Bootstrap
rootfs 分区: ${ROOTFS_PARTSIZE} MB

产物：
1. ${MODEL_NAME}-FriendlyWrt-${FRIENDLY_VER}.img.gz
2. images-${MODEL_NAME}-FriendlyWrt-${FRIENDLY_VER}.tgz
3. ${MODEL_NAME}-OpenWrt-${FRIENDLY_VER}-sysupgrade.img.gz
4. SHA256SUMS

默认：LAN IP 192.168.3.3/24, 密码 tony
EOF
    ls -lh "$ART"
}

# =============================================================
#  主流程
# =============================================================
main() {
    log "========================================"
    log "FriendlyWrt R5S 编译主脚本"
    log "  REPO_ROOT=$REPO_ROOT"
    log "  ROOTFS_PARTSIZE=$ROOTFS_PARTSIZE"
    log "========================================"

    prepare_workspace
    setup_ccache
    prepare_kernel
    init_config
    apply_customizations
    force_config
    download_and_compile
    package
    finalize_artifacts

    log "========================================"
    log "全部完成"
    log "========================================"
}

main "$@"