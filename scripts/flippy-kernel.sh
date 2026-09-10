#!/bin/bash
# scripts/flippy-kernel.sh
#
# 把 flippy 内核和模块替换到 FriendlyWrt SD 镜像里
#
# Usage:
#   scripts/flippy-kernel.sh apply  <SD_FUSE_DIR> [FLIPPY_VERSION]
#   scripts/flippy-kernel.sh verify <RAW_IMG>
#   scripts/flippy-kernel.sh fetch  [FLIPPY_VERSION]
#   scripts/flippy-kernel.sh show
#
# Env:
#   FLIPPY_CACHE_DIR   缓存目录 (默认 /tmp/flippy-cache)
#   FLIPPY_REPO        仓库 (默认 ophub/kernel)
#   FLIPPY_TAG         release tag (默认 kernel_flippy)
#   FLIPPY_FORCE=1     强制重新应用
#   ROOTFS_TARGET_MB   rootfs 目标大小 MB (默认 2048)
#   FLIPPY_DEBUG=1     打开 set -x 调试

set -euo pipefail

if [ "${FLIPPY_DEBUG:-0}" = "1" ]; then
    set -x
fi

FLIPPY_REPO="${FLIPPY_REPO:-ophub/kernel}"
FLIPPY_TAG="${FLIPPY_TAG:-kernel_flippy}"
FLIPPY_CACHE_DIR="${FLIPPY_CACHE_DIR:-/tmp/flippy-cache}"
FLIPPY_FORCE="${FLIPPY_FORCE:-0}"
ROOTFS_TARGET_MB="${ROOTFS_TARGET_MB:-2048}"

# 原始布局: kernel 40 MiB + rootfs 1 GiB
KERNEL_PART_OLD='0x00014000@0x00012000(kernel),0x00010000@0x00026000(boot),0x00010000@0x00036000(recovery),0x00200000@0x00046000(rootfs),0x00200000@0x00246000(userdata:grow),-@0x00446000(opt:grow)'
# 中间态: kernel 48 MiB + rootfs 1 GiB
PART_KERNEL_ONLY='0x00018000@0x00012000(kernel),0x00010000@0x0002a000(boot),0x00010000@0x0003a000(recovery),0x00200000@0x0004a000(rootfs),0x00200000@0x0024a000(userdata:grow),-@0x0044a000(opt:grow)'
# 目标: kernel 48 MiB + rootfs 2 GiB
KERNEL_PART_NEW='0x00018000@0x00012000(kernel),0x00010000@0x0002a000(boot),0x00010000@0x0003a000(recovery),0x00400000@0x0004a000(rootfs),0x00200000@0x0044a000(userdata:grow),-@0x0064a000(opt:grow)'

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log()  { echo -e "${GREEN}[flippy]${NC} $*"; }
warn() { echo -e "${YELLOW}[flippy]${NC} $*" >&2; }
err()  { echo -e "${RED}[flippy]${NC} $*" >&2; exit 1; }

usage() {
    cat <<'EOF'
Usage:
  scripts/flippy-kernel.sh apply  <SD_FUSE_DIR> [FLIPPY_VERSION]
  scripts/flippy-kernel.sh verify <RAW_IMG>
  scripts/flippy-kernel.sh fetch  [FLIPPY_VERSION]
  scripts/flippy-kernel.sh show

Env:
  FLIPPY_CACHE_DIR   缓存目录 (默认 /tmp/flippy-cache)
  FLIPPY_REPO        仓库 (默认 ophub/kernel)
  FLIPPY_TAG         release tag (默认 kernel_flippy)
  FLIPPY_FORCE=1     强制重新应用
  ROOTFS_TARGET_MB   rootfs 目标大小 MB (默认 2048)
  FLIPPY_DEBUG=1     打开 set -x 调试
EOF
    exit 0
}

check_tools() {
    local missing=()
    local t
    for t in wget tar xxd python3 simg2img img2simg file e2fsck resize2fs; do
        if ! command -v "$t" >/dev/null 2>&1; then
            missing+=("$t")
        fi
    done
    if [ ${#missing[@]} -gt 0 ]; then
        err "缺少工具: ${missing[*]}
  安装: sudo apt-get install -y wget tar xxd python3 file android-sdk-libsparse-utils e2fsprogs"
    fi
    return 0
}

get_latest_version() {
    local assets=""
    if command -v gh >/dev/null 2>&1 && [ -n "${GH_TOKEN:-}" ]; then
        assets=$(gh release view "$FLIPPY_TAG" --repo "$FLIPPY_REPO" --json assets --jq '.assets[].name' 2>/dev/null || true)
    fi
    if [ -z "$assets" ]; then
        assets=$(curl -sL "https://api.github.com/repos/$FLIPPY_REPO/releases/tags/$FLIPPY_TAG" \
            | python3 -c "import json,sys
d=json.load(sys.stdin)
for a in d.get('assets',[]):
    print(a['name'])" 2>/dev/null || true)
    fi
    # 避免 pipefail 因为 grep 无匹配返回 1 而中断
    local version
    version=$(echo "$assets" | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.tar\.gz$' | sed 's/\.tar\.gz//' | sort -V | tail -1 || true)
    echo "$version"
    return 0
}

fetch_flippy() {
    local version="${1:-}"
    check_tools

    if [ -z "$version" ]; then
        version=$(get_latest_version)
    fi
    if [ -z "$version" ]; then
        err "无法获取 flippy 版本"
    fi

    local ver_dir="$FLIPPY_CACHE_DIR/$version"
    mkdir -p "$FLIPPY_CACHE_DIR"

    if [ -f "$ver_dir/.ready" ]; then
        echo "$ver_dir"
        return 0
    fi

    log "下载 flippy $version ..." >&2
    local tarball="$FLIPPY_CACHE_DIR/$version.tar.gz"
    if [ ! -f "$tarball" ]; then
        if ! wget -q "https://github.com/$FLIPPY_REPO/releases/download/$FLIPPY_TAG/${version}.tar.gz" -O "$tarball"; then
            err "下载 flippy 失败: $version"
        fi
    fi

    log "解压 flippy 包 ..." >&2
    local tmp_extract="$FLIPPY_CACHE_DIR/.extract.$$"
    rm -rf "$tmp_extract"
    mkdir -p "$tmp_extract"
    tar xzf "$tarball" -C "$tmp_extract"
    local kdir="$tmp_extract/$version"
    if [ ! -d "$kdir" ]; then
        err "解压后找不到 $kdir"
    fi

    rm -rf "$ver_dir"
    mkdir -p "$ver_dir/boot" "$ver_dir/modules"
    tar xzf "$(find "$kdir" -name 'boot-*.tar.gz' | head -1)" -C "$ver_dir/boot"
    tar xzf "$(find "$kdir" -name 'modules-*.tar.gz' | head -1)" -C "$ver_dir/modules"
    rm -rf "$tmp_extract"

    touch "$ver_dir/.ready"
    echo "$ver_dir"
    return 0
}

kernel_already_flippy() {
    local kimg="$1"
    if [ ! -f "$kimg" ]; then
        return 1
    fi
    if grep -a -q "flippy" "$kimg" 2>/dev/null; then
        return 0
    fi
    return 1
}

rootfs_partition_size_mb() {
    local param="$1"
    python3 << PYEOF
import re
with open("$param") as f:
    content = f.read()
m = re.search(r'(0x[0-9a-fA-F]+)@(0x[0-9a-fA-F]+)\(rootfs\)', content)
if m:
    print(int(m.group(1), 16) * 512 // (1024 * 1024))
PYEOF
    return 0
}

# ============================================================
# 通用：从文件里 grep 一个字符串，不用管道
# 返回 0 = 找到，1 = 没找到
# ============================================================
file_contains() {
    local file="$1"
    local pattern="$2"
    if [ ! -f "$file" ]; then
        return 1
    fi
    if grep -a -q "$pattern" "$file" 2>/dev/null; then
        return 0
    fi
    return 1
}

# ============================================================
# 通用：从 raw 镜像的某个偏移抽一段出来到临时文件
# raw_extract <raw> <offset_sectors> <size_sectors> <out_file>
# ============================================================
raw_extract() {
    local raw="$1"
    local offset_sh="$2"
    local size_sh="$3"
    local out="$4"

    # 用 bs=1M 分块，避免大 offset 时的字节级 I/O 慢
    # 注意：offset_sh 是 512 字节扇区数，转换为 1M 需要精确处理
    # 用 dd bs=512 兼容所有情况
    if ! dd if="$raw" of="$out" bs=512 skip="$offset_sh" count="$size_sh" status=none; then
        return 1
    fi
    return 0
}

# ============================================================
# verify_sd_fuse
# ============================================================
verify_sd_fuse() {
    local sd_fuse_dir="$1"
    local kimg="$sd_fuse_dir/kernel.img"
    local rimg="$sd_fuse_dir/rootfs.img"
    local param="$sd_fuse_dir/parameter.txt"

    log "验证 sd-fuse 目录: $sd_fuse_dir"

    if [ ! -f "$kimg" ]; then
        err "kernel.img 不存在"
    fi
    log "  kernel.img 大小: $(stat -c%s "$kimg") bytes"

    if ! kernel_already_flippy "$kimg"; then
        err "kernel.img 里没有 flippy 字符串"
    fi

    local magic_off
    magic_off=$(python3 -c "
data = open('$kimg','rb').read(256)
print(data.find(b'ARM\x64'))
")
    if [ "$magic_off" != "64" ]; then
        err "kernel.img ARM64 magic 位置 0x$(printf %x "$magic_off") != 0x40"
    fi
    log "  ✓ kernel.img 含 flippy + ARM64 magic at 0x40"

    local raw="/tmp/verify_sd.$$.raw.img"
    local mnt="/tmp/verify_sd_mnt.$$"
    if ! simg2img "$rimg" "$raw"; then
        err "rootfs.img simg2img 失败"
    fi
    sudo mkdir -p "$mnt"
    if ! sudo mount -o loop,ro "$raw" "$mnt"; then
        rm -f "$raw"
        err "挂载 rootfs.img 失败"
    fi
    local mods
    mods=$(sudo ls "$mnt/lib/modules/" 2>/dev/null || true)
    sudo umount "$mnt" 2>/dev/null || true
    sudo rmdir "$mnt" 2>/dev/null || true
    rm -f "$raw"

    if ! echo "$mods" | grep -q flippy; then
        err "rootfs.img 里没有 flippy 模块: ${mods:-<empty>}"
    fi
    log "  ✓ rootfs.img 含 flippy modules: $mods"

    local part_mb
    part_mb=$(rootfs_partition_size_mb "$param")
    log "  rootfs 分区大小: ${part_mb} MB"
    if [ "$part_mb" -lt 2048 ]; then
        warn "  rootfs 分区 < 2048 MB"
    fi

    return 0
}

# ============================================================
# apply_flippy
# ============================================================
apply_flippy() {
    local sd_fuse_dir="${1:-}"
    local version="${2:-}"

    if [ -z "$sd_fuse_dir" ]; then
        err "用法: $0 apply <SD_FUSE_DIR> [FLIPPY_VERSION]"
    fi
    if [ ! -d "$sd_fuse_dir" ]; then
        err "目录不存在: $sd_fuse_dir"
    fi

    local param="$sd_fuse_dir/parameter.txt"
    local kimg="$sd_fuse_dir/kernel.img"
    local rimg="$sd_fuse_dir/rootfs.img"

    if [ ! -f "$param" ]; then err "缺少 parameter.txt"; fi
    if [ ! -f "$kimg" ];  then err "缺少 kernel.img"; fi
    if [ ! -f "$rimg" ];  then err "缺少 rootfs.img"; fi

    local ver_dir
    ver_dir=$(fetch_flippy "$version")
    log "flippy 缓存: $ver_dir"

    local vmlinuz
    vmlinuz=$(find "$ver_dir/boot" -name "vmlinuz-*" | head -1)
    if [ -z "$vmlinuz" ]; then
        err "flippy vmlinuz 未找到"
    fi
    local vmlinuz_size
    vmlinuz_size=$(stat -c%s "$vmlinuz")
    log "flippy vmlinuz: $(basename "$vmlinuz") ($vmlinuz_size bytes)"

    local modules_name
    modules_name=$(ls "$ver_dir/modules" | head -1)
    if [ -z "$modules_name" ]; then
        err "flippy modules 未找到"
    fi
    log "flippy modules: $modules_name"

    # ---------- 1. 扩展 kernel + rootfs 分区 ----------
    if grep -q "0x00400000@0x0004a000(rootfs)" "$param"; then
        log "parameter.txt 已是目标布局，跳过"
    elif grep -q "$PART_KERNEL_ONLY" "$param"; then
        log "parameter.txt 已是 kernel 48MiB，扩展 rootfs 到 2 GiB"
        sed -i "s|$PART_KERNEL_ONLY|$KERNEL_PART_NEW|" "$param"
        if ! grep -q "0x00400000@0x0004a000(rootfs)" "$param"; then
            err "parameter.txt rootfs 扩展失败"
        fi
    elif grep -q "$KERNEL_PART_OLD" "$param"; then
        log "parameter.txt 原始布局，扩展到 kernel 48MiB + rootfs 2 GiB"
        sed -i "s|$KERNEL_PART_OLD|$KERNEL_PART_NEW|" "$param"
        if ! grep -q "0x00400000@0x0004a000(rootfs)" "$param"; then
            err "parameter.txt 修改失败"
        fi
    else
        err "parameter.txt 格式不认识"
    fi

    # ---------- 2. 替换 kernel.img ----------
    if [ "$FLIPPY_FORCE" != "1" ] && kernel_already_flippy "$kimg"; then
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

        if ! kernel_already_flippy "$kimg"; then
            err "kernel.img 替换后立即验证失败：找不到 flippy 字符串"
        fi
        log "  ✓ kernel.img 已含 flippy"
    fi

    # ---------- 3. 替换 rootfs.img 里的 modules ----------
    log "处理 rootfs.img (Android sparse)"

    local raw="/tmp/rootfs_work.$$.raw.img"
    local mnt="/tmp/rootfs_mnt.$$"
    local target_bytes=$((ROOTFS_TARGET_MB * 1024 * 1024))

    rm -f "$raw"
    if ! simg2img "$rimg" "$raw"; then
        err "simg2img 失败"
    fi
    local raw_size
    raw_size=$(stat -c%s "$raw")
    log "  raw ext4 原始大小: $raw_size bytes"

    sudo mkdir -p "$mnt"
    sudo mount -o loop,ro "$raw" "$mnt"
    local existing
    existing=$(sudo ls "$mnt/lib/modules/" 2>/dev/null | head -1 || true)
    sudo umount "$mnt"

    if [ "$FLIPPY_FORCE" != "1" ] && echo "$existing" | grep -q flippy && [ "$raw_size" -ge "$target_bytes" ]; then
        log "  rootfs 已是 flippy 模块 ($existing) 且容量已扩，跳过"
        rm -f "$raw"
    else
        if [ "$raw_size" -lt "$target_bytes" ]; then
            log "  扩容 raw ext4: $raw_size -> $target_bytes bytes"
            truncate -s "$target_bytes" "$raw"
            log "  e2fsck 检查 ..."
            sudo e2fsck -f -y "$raw" >/dev/null 2>&1 || warn "  e2fsck 有警告（正常）"
            log "  resize2fs ..."
            if ! sudo resize2fs "$raw" >/dev/null 2>&1; then
                err "resize2fs 失败"
            fi
            log "  扩容后: $(stat -c%s "$raw") bytes"
        fi

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

        sudo rm -rf "$mnt/var/cache/opkg/"* 2>/dev/null || true
        sudo rm -rf "$mnt/tmp/"* 2>/dev/null || true

        local avail
        avail=$(sudo df -h "$mnt" | tail -1)
        log "  替换后使用情况: $avail"

        sudo umount "$mnt"

        if ! img2simg "$raw" "$rimg"; then
            rm -f "$raw"
            err "img2simg 失败"
        fi
        log "  rootfs.img -> $(stat -c%s "$rimg") bytes (sparse)"
        rm -f "$raw"
    fi
    sudo rmdir "$mnt" 2>/dev/null || true

    verify_sd_fuse "$sd_fuse_dir"
    log "✓ apply 完成"
    return 0
}

# ============================================================
# verify_raw
# ============================================================
verify_raw() {
    local raw="${1:-}"
    if [ -z "$raw" ]; then
        err "用法: $0 verify <RAW_IMG>"
    fi
    if [ ! -f "$raw" ]; then
        err "镜像不存在: $raw"
    fi
    log "验证 raw 镜像: $raw ($(stat -c%s "$raw") bytes)"

    # ---------- kernel 分区 ----------
    local kernel_offset_sh=$((0x12000))
    local kernel_size_sh=$((0x18000))   # 48 MiB
    local kernel_part="/tmp/verify_kernel_part.$$.bin"

    # 只读前 8 字节检查 KRNL 头，然后从头读整个 kernel 分区到临时文件
    raw_extract "$raw" "$kernel_offset_sh" "$kernel_size_sh" "$kernel_part"
    if [ ! -s "$kernel_part" ]; then
        rm -f "$kernel_part"
        err "提取 kernel 分区失败"
    fi
    log "  kernel 分区提取: $(stat -c%s "$kernel_part") bytes"

    # ARM64 magic 检查（KRNL 8 字节头之后 0x38 位置 = 分区里 0x40）
    local magic_pos
    magic_pos=$(python3 -c "
data = open('$kernel_part','rb').read(256)
print(data.find(b'ARM\x64'))
")
    if [ "$magic_pos" != "64" ]; then
        rm -f "$kernel_part"
        err "kernel 分区 ARM64 magic at 0x$(printf %x "$magic_pos")，期望 0x40"
    fi
    log "  ✓ kernel 分区 ARM64 magic at 0x40"

    # flippy 字符串检查（在文件里 grep，不用管道）
    if ! file_contains "$kernel_part" "flippy"; then
        rm -f "$kernel_part"
        err "kernel 分区里没有 flippy 字符串"
    fi
    rm -f "$kernel_part"
    log "  ✓ kernel 分区含 flippy"

    # ---------- rootfs 分区 ----------
    local rootfs_offset_sh=$((0x4a000))
    local rootfs_size_sh=$((0x400000))  # 2 GiB
    local sparse="/tmp/verify_sparse.$$"
    local vraw="/tmp/verify_raw.$$"
    local mnt="/tmp/verify_rootfs_mnt.$$"

    raw_extract "$raw" "$rootfs_offset_sh" "$rootfs_size_sh" "$sparse"
    if [ ! -s "$sparse" ]; then
        err "提取 rootfs 分区失败"
    fi
    log "  rootfs 分区提取: $(stat -c%s "$sparse") bytes"

    local magic
    magic=$(xxd -l 4 -p "$sparse")
    if [ "$magic" = "3aff26ed" ]; then
        if ! simg2img "$sparse" "$vraw"; then
            rm -f "$sparse"
            err "rootfs 分区 simg2img 失败"
        fi
    else
        mv "$sparse" "$vraw"
    fi
    rm -f "$sparse"

    local ext4_magic
    ext4_magic=$(xxd -s 0x438 -l 2 -p "$vraw")
    if [ "$ext4_magic" != "53ef" ]; then
        rm -f "$vraw"
        err "rootfs 分区不是 ext4（magic @ 0x438 = $ext4_magic）"
    fi

    sudo mkdir -p "$mnt"
    if ! sudo mount -o loop,ro "$vraw" "$mnt"; then
        rm -f "$vraw"
        err "挂载 rootfs 失败"
    fi
    local mods
    mods=$(sudo ls "$mnt/lib/modules/" 2>/dev/null || true)
    local df_out
    df_out=$(sudo df -h "$mnt" | tail -1)
    sudo umount "$mnt"
    sudo rmdir "$mnt" 2>/dev/null || true
    rm -f "$vraw"

    if ! echo "$mods" | grep -q flippy; then
        err "rootfs 分区里没有 flippy 模块: ${mods:-<empty>}"
    fi
    log "  ✓ rootfs 分区含 flippy modules: $mods"
    log "  rootfs 使用: $df_out"

    log "✓ 验证通过"
    return 0
}

# ============================================================
# 主入口
# ============================================================
cmd="${1:-}"
case "$cmd" in
    apply)   shift; apply_flippy "$@" ;;
    verify)  shift; verify_raw "$@" ;;
    fetch)   shift; fetch_flippy "$@" ;;
    show)    get_latest_version ;;
    ""|-h|--help|help) usage ;;
    *) err "未知命令: $cmd" ;;
esac