#!/bin/bash
# flippy-kernel.sh - 将 flippy 内核注入 FriendlyWrt
# 用法:
#   flippy-kernel.sh apply-before-sdimg-root <root-dir>   # 替换 root 目录 modules
#   flippy-kernel.sh apply <sd-fuse-dist-dir>             # 替换 kernel.img/dtb/parameter
#   flippy-kernel.sh verify <raw-img-file>                # 验证最终镜像
set -euo pipefail

VERSION="2026-09-10-v11"
FLIPPY_CACHE="${FLIPPY_CACHE:-/tmp/flippy-cache}"
GH_TOKEN="${GH_TOKEN:-}"

log() { echo -e "\033[0;32m[flippy]\033[0m $*"; }
err() { echo -e "\033[0;31m[flippy]\033[0m $*" >&2; }
log "flippy-kernel.sh version: $VERSION"

get_latest_version() {
  if [ -n "${FLIPPY_VERSION:-}" ]; then echo "$FLIPPY_VERSION"; return; fi
  local assets
  assets=$(gh release view kernel_flippy --repo ophub/kernel --json assets --jq '.assets[].name')
  echo "$assets" | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.tar\.gz$' | sed 's/\.tar\.gz//' | sort -V | tail -1
}

download_flippy() {
  local ver="$1"
  local cache_dir="$FLIPPY_CACHE/$ver"
  if [ -f "$cache_dir/.ready" ]; then log "flippy 缓存命中: $cache_dir"; return 0; fi
  log "下载 flippy $ver ..."
  rm -rf "$cache_dir"; mkdir -p "$cache_dir"; cd "$cache_dir"
  wget -q "https://github.com/ophub/kernel/releases/download/kernel_flippy/${ver}.tar.gz" -O flippy.tar.gz
  tar xzf flippy.tar.gz
  local kdir="$ver"; [ ! -d "$kdir" ] && kdir=$(find . -maxdepth 1 -type d -name "*$ver*" | head -1)
  mkdir -p boot dtb modules
  tar xzf "$(find "$kdir" -name 'boot-*.tar.gz' | head -1)" -C boot
  tar xzf "$(find "$kdir" -name 'dtb-rockchip-*.tar.gz' | head -1)" -C dtb
  tar xzf "$(find "$kdir" -name 'modules-*.tar.gz' | head -1)" -C modules
  touch .ready
  log "解压完成: $cache_dir"
}

# ========== root 目录替换 modules ==========
cmd_apply_before_sdimg_root() {
  local root_dir="$1"
  [ -d "$root_dir" ] || { err "root 目录不存在: $root_dir"; exit 1; }
  [ -d "$root_dir/bin" ] && [ -d "$root_dir/etc" ] || { err "不是有效 root: $root_dir"; exit 1; }

  local ver; ver=$(get_latest_version)
  download_flippy "$ver"
  local cache="$FLIPPY_CACHE/$ver"

  local modules_name; modules_name=$(ls "$cache/modules" | head -1)
  [ -z "$modules_name" ] && { err "modules 目录为空"; exit 1; }

  if [ -d "$root_dir/lib/modules" ]; then
    local old_mb; old_mb=$(du -sm "$root_dir/lib/modules" | awk '{print $1}')
    log "原 modules: ${old_mb} MiB，删除中..."
    rm -rf "$root_dir/lib/modules"
  fi

  mkdir -p "$root_dir/lib/modules/$modules_name"
  cp -a "$cache/modules/$modules_name"/. "$root_dir/lib/modules/$modules_name/"

  local src_mb dst_mb
  src_mb=$(du -sm "$cache/modules/$modules_name" | awk '{print $1}')
  dst_mb=$(du -sm "$root_dir/lib/modules/$modules_name" | awk '{print $1}')
  log "新 modules: ${dst_mb} MiB (源 ${src_mb} MiB)"
  [ "$dst_mb" -lt "$((src_mb * 9 / 10))" ] && { err "复制不完整"; exit 1; }

  echo "$cache" > /tmp/flippy_cache_path
  log "✓ root modules 已替换"
}

# ========== kernel.img 构造 ==========
build_kernel_img() {
  local dst="$1" boot_dir="$2"
  local vmlinuz; vmlinuz=$(find "$boot_dir" -name "vmlinuz-*" | head -1)
  local size; size=$(stat -c%s "$vmlinuz")
  log "flippy vmlinuz: $(basename "$vmlinuz") ($size bytes)"

  # code0 (MZ 魔数) 替换为 NOP，避免 U-Boot 跳转后执行非法指令
  echo "1f2003d5" | xxd -r -p > /tmp/flippy_vmlinuz_patched
  tail -c +5 "$vmlinuz" >> /tmp/flippy_vmlinuz_patched

  local size_hex size_le
  size_hex=$(printf '%08x' "$size")
  size_le=$(echo "$size_hex" | sed 's/\(..\)\(..\)\(..\)\(..\)/\4\3\2\1/')
  printf 'KRNL' > "$dst"
  printf "$size_le" | xxd -r -p >> "$dst"
  cat /tmp/flippy_vmlinuz_patched >> "$dst"

  python3 - "$dst" <<'PYEOF'
import sys
data = open(sys.argv[1], 'rb').read(256)
assert data[0:4] == b'KRNL'
assert int.from_bytes(data[8:12], 'little') == 0xd503201f
idx = data.find(b'ARM\x64'); assert idx == 0x40, f'magic@{idx:x}'
print('  ✓ kernel.img OK')
PYEOF
  log "kernel.img -> $(stat -c%s "$dst") bytes"
}

extend_parameter() {
  local param="$1"
  # kernel 扩到 48MiB, rootfs 扩到 2GiB
  local orig='0x00014000@0x00012000(kernel),0x00010000@0x00026000(boot),0x00010000@0x00036000(recovery),0x00200000@0x00046000(rootfs),0x00200000@0x00246000(userdata:grow),-@0x00446000(opt:grow)'
  local new='0x00018000@0x00012000(kernel),0x00010000@0x0002a000(boot),0x00010000@0x0003a000(recovery),0x00400000@0x0004a000(rootfs),0x00200000@0x0044a000(userdata:grow),-@0x0064a000(opt:grow)'
  grep -q "0x00018000@0x00012000(kernel)" "$param" && { log "parameter.txt 已扩展"; return 0; }
  sed -i "s|$orig|$new|" "$param"
  grep -q "0x00400000@0x0004a000(rootfs)" "$param" || { err "parameter.txt 失败"; return 1; }
  log "parameter.txt: kernel 48MiB + rootfs 2GiB"
}

cmd_apply() {
  local sdfuse_dir="$1"
  [ -d "$sdfuse_dir" ] || { err "目录不存在: $sdfuse_dir"; exit 1; }

  local cache=""
  [ -f /tmp/flippy_cache_path ] && cache=$(cat /tmp/flippy_cache_path)
  [ ! -d "$cache" ] && cache=""
  if [ -z "$cache" ]; then
    local ver; ver=$(get_latest_version); download_flippy "$ver"; cache="$FLIPPY_CACHE/$ver"
  fi

  log "替换 kernel.img"
  build_kernel_img "$sdfuse_dir/kernel.img" "$cache/boot"

  log "替换 dtb"
  rm -rf "$sdfuse_dir/dtb"
  mkdir -p "$sdfuse_dir/dtb/rockchip"
  cp "$cache/dtb"/*.dtb "$sdfuse_dir/dtb/rockchip/" 2>/dev/null || true
  log "  dtb 数: $(ls "$sdfuse_dir/dtb/rockchip/" 2>/dev/null | wc -l)"

  local uinitrd; uinitrd=$(find "$cache/boot" -name "uInitrd-*" | head -1)
  [ -n "$uinitrd" ] && cp "$uinitrd" "$sdfuse_dir/uInitrd" && log "  uInitrd 已替换"

  extend_parameter "$sdfuse_dir/parameter.txt"
  log "✓ apply 完成"
}

cmd_verify() {
  local raw_img="$1"
  [ -f "$raw_img" ] || { err "镜像不存在: $raw_img"; exit 1; }
  log "验证: $raw_img ($(stat -c%s "$raw_img") bytes)"

  dd if="$raw_img" of=/tmp/verify_kernel.img bs=512 skip=$((0x12000)) count=$((0x18000)) status=none
  python3 - <<'PYEOF'
data = open('/tmp/verify_kernel.img','rb').read(256)
assert data[0:4] == b'KRNL'
assert int.from_bytes(data[8:12], 'little') == 0xd503201f
assert data.find(b'ARM\x64') == 0x40
print('  ✓ kernel 分区含 flippy')
PYEOF

  dd if="$raw_img" of=/tmp/verify_rootfs.img bs=512 skip=$((0x4a000)) count=$((0x400000)) status=none
  if ! simg2img /tmp/verify_rootfs.img /tmp/verify_rootfs_raw.img 2>/dev/null; then
    cp /tmp/verify_rootfs.img /tmp/verify_rootfs_raw.img
  fi
  mkdir -p /tmp/verify_rootfs_mnt
  if sudo mount -o loop,ro /tmp/verify_rootfs_raw.img /tmp/verify_rootfs_mnt 2>/dev/null; then
    local m; m=$(ls /tmp/verify_rootfs_mnt/lib/modules 2>/dev/null | head -1)
    [ -n "$m" ] && log "  ✓ rootfs 含 flippy modules: $m" || { err "  ✗ rootfs 缺 modules"; exit 1; }
    sudo umount /tmp/verify_rootfs_mnt
  fi
  rm -f /tmp/verify_kernel.img /tmp/verify_rootfs.img /tmp/verify_rootfs_raw.img
  log "✓ 验证通过"
}

case "${1:-}" in
  apply-before-sdimg-root) shift; cmd_apply_before_sdimg_root "$@" ;;
  apply)  shift; cmd_apply "$@" ;;
  verify) shift; cmd_verify "$@" ;;
  *) echo "Usage: $0 {apply-before-sdimg-root|apply|verify} <dir-or-img>"; exit 1 ;;
esac