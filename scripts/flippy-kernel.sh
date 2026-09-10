#!/bin/bash
# scripts/flippy-kernel.sh
#
# 处理 FriendlyWrt SD 镜像的 flippy 内核替换
#
# Usage:
#   ./scripts/flippy-kernel.sh apply  <SD_FUSE_DIR> [FLIPPY_VERSION]
#   ./scripts/flippy-kernel.sh verify <RAW_IMG>
#   ./scripts/flippy-kernel.sh fetch  [FLIPPY_VERSION]
#   ./scripts/flippy-kernel.sh show
#
# Env:
#   FLIPPY_CACHE_DIR   缓存目录 (默认 /tmp/flippy-cache)
#   FLIPPY_REPO        (默认 ophub/kernel)
#   FLIPPY_TAG         (默认 kernel_flippy)

set -euo pipefail

FLIPPY_REPO="${FLIPPY_REPO:-ophub/kernel}"
FLIPPY_TAG="${FLIPPY_TAG:-kernel_flippy}"
FLIPPY_CACHE_DIR="${FLIPPY_CACHE_DIR:-/tmp/flippy-cache}"

# kernel 分区从 0x14000 (40 MiB) 扩到 0x18000 (48 MiB)
KERNEL_PART_OLD='0x00014000@0x00012000(kernel),0x00010000@0x00026000(boot),0x00010000@0x00036000(recovery),0x00200000@0x00046000(rootfs),0x00200000@0x00246000(userdata:grow),-@0x00446000(opt:grow)'
KERNEL_PART_NEW='0x00018000@0x00012000(kernel),0x00010000@0x0002a000(boot),0x00010000@0x0003a000(recovery),0x00200000@0x0004a000(rootfs),0x00200000@0x0024a000(userdata:grow),-@0x0044a000(opt:grow)'

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log()  { echo -e "${GREEN}[flippy]${NC} $*"; }
warn() { echo -e "${YELLOW}[flippy]${NC} $*" >&2; }
err()  { echo -e "${RED}[flippy]${NC} $*" >&2; exit 1; }

usage() {
    sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
    exit 0
}

check_tools() {
    local missing=()
    for t in wget tar xxd python3 simg2img img2simg file; do
        command -v "$t" >/dev/null 2>&1 || missing+=("$t")
    done
    if [ ${#missing[@]} -gt 0 ]; then
        err "缺少工具: ${missing[*]}
  安装: sudo apt-get install -y wget tar xxd python3 file android-sdk-libsparse-utils"
    fi
}

get_latest_version() {
    local assets=""
    if command -v gh >/dev/null 2>&1; then
        assets=$(gh release view "$FLIPPY_TAG" --repo "$FLIPPY_REPO" --json assets --jq '.assets[].name' 2>/dev/null || true)
    fi
    if [ -z "$assets" ]; then
        assets=$(curl -sL "https://api.github.com/repos/$FLIPPY_REPO/releases/tags/$FLIPPY_TAG" \
            | python3 -c "import json,sys; d=json.load(sys.stdin); [print(a['name']) for a in d.get('assets',[])]" 2>/dev/null || true)
    fi
    echo "$assets" | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.tar\.gz$' | sed 's/\.tar\.gz//' | sort -V | tail -1
}

# fetch <version> -> echo cache dir
fetch_flippy() {
    local version="${1:-}"
    check_tools
    if [ -z "$version" ]; then
        version=$(get_latest_version)
    fi
    [ -z "$version" ] && err "无法获取 flippy 版本"

    local ver_dir="$FLIPPY_CACHE_DIR/$version"
    mkdir -p "$FLIPPY_CACHE_DIR"

    if [ -f "$ver_dir/.ready" ]; then
        echo "$ver_dir"
        return 0
    fi

    log "下载 flippy $version ..." >&2
    local tarball="$FLIPPY_CACHE_DIR/$version.tar.gz"
    if [ ! -f "$tarball" ]; then
        wget -q "https://github.com/$FLIPPY_REPO/releases/download/$FLIPPY_TAG/${version}.tar.gz" -O "$tarball" \
            || err "下载 flippy 失败"
    fi

    log "解压 flippy 包 ..." >&2
    local tmp_extract="$FLIPPY_CACHE_DIR/.extract.$$"
    rm -rf "$tmp_extract"
    mkdir -p "$tmp_extract"
    tar xzf "$tarball" -C "$tmp_extract"
    local kdir="$tmp_extract/$version"
    [ ! -d "$kdir" ] && err "解压后找不到 $kdir"

    rm -rf "$ver_dir"
    mkdir -p "$ver_dir/boot" "$ver_dir/modules"
    tar xzf "$(find "$kdir" -name 'boot-*.tar.gz' | head -1)" -C "$ver_dir/boot"
    tar xzf "$(find "$kdir" -name 'modules-*.tar.gz' | head -1)" -C "$ver_dir/modules"
    rm -rf "$tmp_extract"

    touch "$ver_dir/.ready"
    echo "$ver_dir"
}

kernel_already_flippy() {
    local kimg="$1"
    [ -f "$kimg" ] || return 1
    dd if="$kimg" bs=1 skip=8 count=$((40*1024*1024)) 2>/dev/null | grep -a -q "flippy"
}

# apply <sd_fuse_dir> [version]
apply_flippy() {
    local sd_fuse_dir="${1:-}"
    local version="${2:-}"

    [ -z "$sd_fuse_dir" ] && err "用法: $0 apply <SD_FUSE_DIR> [FLIPPY_VERSION]"
    [ ! -d "$sd_fuse_dir" ] && err "目录不存在: $sd_fuse_dir"

    local param="$sd_fuse_dir/parameter.txt"
    local kimg="$sd_fuse_dir/kernel.img"
    local rimg="$sd_fuse_dir/rootfs.img"

    [ ! -f "$param" ] && err "缺少 parameter.txt"
    [ ! -f "$kimg" ]  && err "缺少 kernel.img"
    [ ! -f "$rimg" ]  && err "缺少 rootfs.img"

    # 1. 获取 flippy 包
    local ver_dir
    ver_dir=$(fetch_flippy "$version")
    log "flippy 缓存: $ver_dir"

    local vmlinuz
    vmlinuz=$(find "$ver_dir/boot" -name "vmlinuz-*" | head -1)
    [ -z "$vmlinuz" ] && err "flippy vmlinuz 未找到"
    local vmlinuz_size
    vmlinuz_size=$(stat -c%s "$vmlinuz")
    log "flippy vmlinuz: $(basename "$vmlinuz") ($vmlinuz_size bytes)"

    local modules_name
    modules_name=$(ls "$ver_dir/modules" | head -1)
    [ -z "$modules_name" ] && err "flippy modules 未找到"
    log "flippy modules: $modules_name"

    # 2. 扩展 kernel 分区
    if grep -q "0x00018000@0x00012000(kernel)" "$param"; then
        log "parameter.txt kernel 分区已经是 48 MiB，跳过"
    elif grep -q "0x00014000@0x00012000(kernel)" "$param"; then
        log "扩展 kernel 分区 40 MiB -> 48 MiB"
        sed -i "s|$KERNEL_PART_OLD|$KERNEL_PART_NEW|" "$param"
        grep -q "0x00018000@0x00012000(kernel)" "$param" || err "parameter.txt 修改失败"
    else
        err "parameter.txt 格式不认识，无法扩展 kernel 分区"
    fi

    # 3. 替换 kernel.img
    if kernel_already_flippy "$kimg"; then
        log "kernel.img 已经含 flippy，跳过"
    else
        log "替换 kernel.img"
        local size_hex size_le
        size_hex=$(printf '%08x' "$vmlinuz_size")
        size_le=$(echo "$size_hex" | sed 's/\(..\)\(..\)\(..\)\(..\)/\4\3\2\1/')
        local new_kernel="/tmp/new_kernel.$$.img"
        printf 'KRNL' > "$new_kernel"
        printf "%s" "$size_le" | xxd -r -p >> "$new_kernel"
        cat "$vmlinuz" >> "$new_kernel"

        python3 -c "
data = open('$new_kernel','rb').read(256)
idx = data.find(b'ARM\x64')
assert idx == 0x40, f'ARM64 magic at 0x{idx:x}, expected 0x40'
"
        cp "$new_kernel" "$kimg"
        rm -f "$new_kernel"
        log "kernel.img -> $(stat -c%s "$kimg") bytes"
    fi

    # 4. 替换 rootfs.img 里的 modules
    log "处理 rootfs.img (Android sparse)"
    local raw="/tmp/rootfs_work.$$.raw.img"
    local mnt="/tmp/rootfs_mnt.$$"

    simg2img "$rimg" "$raw" || err "simg2img 失败"
    log "  raw ext4: $(stat -c%s "$raw") bytes"

    sudo mkdir -p "$mnt"
    sudo mount -o loop,ro "$raw" "$mnt"
    local existing
    existing=$(sudo ls "$mnt/lib/modules/" 2>/dev/null | head -1 || true)
    sudo umount "$mnt"

    if echo "$existing" | grep -q flippy; then
        log "  rootfs 里已是 flippy 模块 ($existing)，跳过"
        rm -f "$raw"
    else
        log "  rootfs 当前模块: ${existing:-<empty>}，替换中..."
        sudo mount -o loop "$raw" "$mnt"
        sudo rm -rf "$mnt/lib/modules/"*
        sudo mkdir -p "$mnt/lib/modules"
        sudo cp -a "$ver_dir/modules/$modules_name" "$mnt/lib/modules/"
        local newmods
        newmods=$(sudo ls "$mnt/lib/modules/")
        if ! echo "$newmods" | grep -q flippy; then
            sudo umount "$mnt"
            rm -f "$raw"
            err "替换后 rootfs 里仍无 flippy 模块: $newmods"
        fi
        log "  新模块: $newmods"
        sudo umount "$mnt"

        img2simg "$raw" "$rimg" || err "img2simg 失败"
        local sparse_size
        sparse_size=$(stat -c%s "$rimg")
        log "  rootfs.img -> $sparse_size bytes (sparse)"
        rm -f "$raw"
    fi
    sudo rmdir "$mnt" 2>/dev/null || true

    # 5. 验证
    verify_sd_fuse "$sd_fuse_dir"
    log "✓ apply 完成"
}

verify_sd_fuse() {
    local sd_fuse_dir="$1"
    local kimg="$sd_fuse_dir/kernel.img"
    local rimg="$sd_fuse_dir/rootfs.img"

    log "验证 sd-fuse 目录"

    if ! kernel_already_flippy "$kimg"; then
        err "kernel.img 里没有 flippy"
    fi
    local magic_off
    magic_off=$(python3 -c "
data = open('$kimg','rb').read(256)
print(data.find(b'ARM\x64'))
")
    [ "$magic_off" = "64" ] || err "kernel.img ARM64 magic 位置 0x$(printf %x $magic_off) != 0x40"
    log "  ✓ kernel.img 含 flippy + ARM64 magic at 0x40"

    local raw="/tmp/verify_sd.$$.raw.img"
    local mnt="/tmp/verify_sd_mnt.$$"
    simg2img "$rimg" "$raw"
    sudo mkdir -p "$mnt"
    sudo mount -o loop,ro "$raw" "$mnt"
    local mods
    mods=$(sudo ls "$mnt/lib/modules/" 2>/dev/null || true)
    sudo umount "$mnt"
    sudo rmdir "$mnt" 2>/dev/null || true
    rm -f "$raw"

    if ! echo "$mods" | grep -q flippy; then
        err "rootfs 里没有 flippy 模块: ${mods:-<empty>}"
    fi
    log "  ✓ rootfs.img 含 flippy modules: $mods"
}

# verify <raw_img>
verify_raw() {
    local raw="${1:-}"
    [ -z "$raw" ] && err "用法: $0 verify <RAW_IMG>"
    [ ! -f "$raw" ] && err "镜像不存在: $raw"
    log "验证 raw 镜像: $raw ($(stat -c%s "$raw") bytes)"

    # kernel 分区
    local kernel_offset=$((0x12000 * 512))
    local magic_pos
    magic_pos=$(python3 -c "
with open('$raw','rb') as f:
    f.seek($kernel_offset)
    data = f.read(256)
idx = data.find(b'ARM\x64')
print(idx)
")
    [ "$magic_pos" = "64" ] || err "kernel 分区 ARM64 magic at 0x$(printf %x $magic_pos)，期望 0x40"
    log "  ✓ kernel 分区 ARM64 magic at 0x40"

    if ! dd if="$raw" bs=1 skip=$((kernel_offset + 8)) count=$((44*1024*1024)) 2>/dev/null \
         | grep -a -q "flippy"; then
        err "kernel 分区里没有 flippy"
    fi
    log "  ✓ kernel 分区含 flippy"

    # rootfs 分区
    local rootfs_offset_sh=$((0x4a000))
    local rootfs_size_sh=$((0x200000))
    local sparse="/tmp/verify_sparse.$$"
    local vraw="/tmp/verify_raw.$$"
    dd if="$raw" of="$sparse" bs=512 skip=$rootfs_offset_sh count=$rootfs_size_sh 2>/dev/null
    simg2img "$sparse" "$vraw" || err "rootfs 分区 simg2img 失败"
    local mnt="/tmp/verify_rootfs_mnt.$$"
    sudo mkdir -p "$mnt"
    sudo mount -o loop,ro "$vraw" "$mnt"
    local mods
    mods=$(sudo ls "$mnt/lib/modules/" 2>/dev/null || true)
    sudo umount "$mnt"
    sudo rmdir "$mnt" 2>/dev/null || true
    rm -f "$sparse" "$vraw"

    if ! echo "$mods" | grep -q flippy; then
        err "rootfs 分区里没有 flippy 模块: ${mods:-<empty>}"
    fi
    log "  ✓ rootfs 分区含 flippy modules: $mods"

    log "✓ 验证通过"
}

cmd="${1:-}"
case "$cmd" in
    apply)  shift; apply_flippy "$@" ;;
    verify) shift; verify_raw "$@" ;;
    fetch)  shift; fetch_flippy "$@" ;;
    show)   get_latest_version ;;
    ""|-h|--help|help) usage ;;
    *) err "未知命令: $cmd" ;;
esac