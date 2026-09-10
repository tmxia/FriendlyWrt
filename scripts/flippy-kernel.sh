#!/bin/bash
# flippy-kernel.sh - 将 flippy 内核注入 FriendlyWrt sd-fuse 目录
# 用法:
#   flippy-kernel.sh apply <sd-fuse-dist-dir>
#   flippy-kernel.sh verify <raw-img-file>
set -euo pipefail

VERSION="2026-09-10-v8"

FLIPPY_CACHE="${FLIPPY_CACHE:-/tmp/flippy-cache}"
GH_TOKEN="${GH_TOKEN:-}"

log() { echo -e "\033[0;32m[flippy]\033[0m $*"; }
err() { echo -e "\033[0;31m[flippy]\033[0m $*" >&2; }

log "flippy-kernel.sh version: $VERSION"

get_latest_version() {
  if [ -n "${FLIPPY_VERSION:-}" ]; then
    echo "$FLIPPY_VERSION"; return
  fi
  local assets
  assets=$(gh release view kernel_flippy --repo ophub/kernel --json assets --jq '.assets[].name')
  echo "$assets" | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.tar\.gz$' \
    | sed 's/\.tar\.gz//' | sort -V | tail -1
}

download_flippy() {
  local ver="$1"
  local cache_dir="$FLIPPY_CACHE/$ver"
  if [ -f "$cache_dir/.ready" ]; then
    log "flippy 缓存命中: $cache_dir"; return 0
  fi
  log "下载 flippy $ver ..."
  rm -rf "$cache_dir"
  mkdir -p "$cache_dir"
  cd "$cache_dir"
  wget -q "https://github.com/ophub/kernel/releases/download/kernel_flippy/${ver}.tar.gz" -O flippy.tar.gz
  tar xzf flippy.tar.gz
  local kdir="$ver"
  [ ! -d "$kdir" ] && kdir=$(find . -maxdepth 1 -type d -name "*$ver*" | head -1)
  mkdir -p boot dtb modules
  tar xzf "$(find "$kdir" -name 'boot-*.tar.gz' | head -1)" -C boot
  tar xzf "$(find "$kdir" -name 'dtb-rockchip-*.tar.gz' | head -1)" -C dtb
  tar xzf "$(find "$kdir" -name 'modules-*.tar.gz' | head -1)" -C modules
  touch .ready
  log "解压完成: $cache_dir"
}

build_kernel_img() {
  local dst="$1"
  local boot_dir="$2"
  local vmlinuz
  vmlinuz=$(find "$boot_dir" -name "vmlinuz-*" | head -1)
  local size
  size=$(stat -c%s "$vmlinuz")

  log "flippy vmlinuz: $(basename "$vmlinuz") ($size bytes)"

  # 关键修复: flippy vmlinuz 是 EFI stub, code0 是 MZ 魔数(非法指令)
  # RK3568 U-Boot 直接跳转到 code0, 执行 MZ 会崩溃
  # 替换为 NOP 指令(0xd503201f), 让 CPU 继续执行 code1 的合法分支
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
assert data[0:4] == b'KRNL', 'KRNL magic missing'
code0 = int.from_bytes(data[8:12], 'little')
assert code0 == 0xd503201f, f'code0 not NOP: 0x{code0:08x}'
idx = data.find(b'ARM\x64')
assert idx == 0x40, f'ARM64 magic at 0x{idx:x}'
print(f"  ✓ kernel.img OK: KRNL + NOP + ARM64 magic@0x40")
PYEOF

  log "kernel.img -> $(stat -c%s "$dst") bytes"
}

extend_parameter() {
  local param="$1"
  local orig='0x00014000@0x00012000(kernel),0x00010000@0x00026000(boot),0x00010000@0x00036000(recovery),0x00200000@0x00046000(rootfs),0x00200000@0x00246000(userdata:grow),-@0x00446000(opt:grow)'
  local new='0x00018000@0x00012000(kernel),0x00010000@0x0002a000(boot),0x00010000@0x0003a000(recovery),0x00200000@0x0004a000(rootfs),0x00200000@0x0024a000(userdata:grow),-@0x0044a000(opt:grow)'
  if grep -q "0x00018000@0x00012000(kernel)" "$param"; then
    log "parameter.txt 已扩展"; return 0
  fi
  sed -i "s|$orig|$new|" "$param"
  grep -q "0x00018000@0x00012000(kernel)" "$param" || { err "parameter.txt 修改失败"; return 1; }
  log "parameter.txt: kernel 分区 40 MiB -> 48 MiB"
}

process_rootfs() {
  local rootfs_img="$1"
  local modules_dir="$2"
  local modules_name
  modules_name=$(ls "$modules_dir" | head -1)
  [ -z "$modules_name" ] && { err "modules 目录为空"; return 1; }

  log "处理 rootfs.img (Android sparse)"
  local raw_img="/tmp/flippy_rootfs_raw.img"
  local mnt="/tmp/flippy_rootfs_mnt"
  rm -f "$raw_img"
  simg2img "$rootfs_img" "$raw_img"
  local orig_size
  orig_size=$(stat -c%s "$raw_img")
  log "  raw ext4 原始大小: $orig_size bytes"

  local target_size=$((2*1024*1024*1024))
  if [ "$orig_size" -lt "$target_size" ]; then
    truncate -s "$target_size" "$raw_img"
    log "  扩容 raw ext4: $orig_size -> $target_size bytes"
    e2fsck -f -y "$raw_img" >/dev/null 2>&1 || true
    log "  e2fsck 检查 ..."
    resize2fs "$raw_img" >/dev/null 2>&1
    log "  resize2fs ..."
  fi

  mkdir -p "$mnt"
  sudo mount -o loop "$raw_img" "$mnt"
  local old_mod
  old_mod=$(ls "$mnt/lib/modules" 2>/dev/null | head -1 || true)
  log "  rootfs 当前模块: ${old_mod:-none}，替换中..."
  sudo rm -rf "$mnt/lib/modules"
  sudo mkdir -p "$mnt/lib/modules/$modules_name"
  sudo cp -a "$modules_dir/$modules_name"/. "$mnt/lib/modules/$modules_name/"
  log "  新模块: $modules_name"
  df -h "$mnt" | tail -1
  sudo umount "$mnt"

  img2simg "$raw_img" "$rootfs_img"
  log "  rootfs.img -> $(stat -c%s "$rootfs_img") bytes (sparse)"
  rm -f "$raw_img"
}

cmd_apply() {
  local sdfuse_dir="$1"
  [ -d "$sdfuse_dir" ] || { err "目录不存在: $sdfuse_dir"; exit 1; }

  local ver
  ver=$(get_latest_version)
  [ -z "$ver" ] && { err "无法获取 flippy 版本"; exit 1; }
  download_flippy "$ver"
  local cache="$FLIPPY_CACHE/$ver"

  log "替换 kernel.img"
  build_kernel_img "$sdfuse_dir/kernel.img" "$cache/boot"

  log "替换 dtb"
  rm -rf "$sdfuse_dir/dtb"
  mkdir -p "$sdfuse_dir/dtb/rockchip"
  cp "$cache/dtb"/*.dtb "$sdfuse_dir/dtb/rockchip/" 2>/dev/null || true
  log "  dtb 文件数: $(ls "$sdfuse_dir/dtb/rockchip/" 2>/dev/null | wc -l)"

  local uinitrd
  uinitrd=$(find "$cache/boot" -name "uInitrd-*" | head -1)
  if [ -n "$uinitrd" ]; then
    cp "$uinitrd" "$sdfuse_dir/uInitrd"
    log "  uInitrd 已替换"
  fi

  if [ -f "$sdfuse_dir/rootfs.img" ]; then
    process_rootfs "$sdfuse_dir/rootfs.img" "$cache/modules"
  fi

  extend_parameter "$sdfuse_dir/parameter.txt"

  log "验证 sd-fuse 目录: $sdfuse_dir"
  log "  kernel.img 大小: $(stat -c%s "$sdfuse_dir/kernel.img") bytes"
  python3 - "$sdfuse_dir/kernel.img" <<'PYEOF'
import sys
data = open(sys.argv[1], 'rb').read(256)
assert data[0:4] == b'KRNL'
code0 = int.from_bytes(data[8:12], 'little')
assert code0 == 0xd503201f
idx = data.find(b'ARM\x64')
assert idx == 0x40
print('  ✓ kernel.img 含 flippy + code0=NOP + ARM64 magic@0x40')
PYEOF

  log "✓ apply 完成 (version $VERSION)"
}

cmd_verify() {
  local raw_img="$1"
  [ -f "$raw_img" ] || { err "镜像不存在: $raw_img"; exit 1; }

  log "验证 raw 镜像: $raw_img ($(stat -c%s "$raw_img") bytes)"

  # kernel 分区偏移 0x12000 扇区, 大小 0x18000 扇区
  dd if="$raw_img" of=/tmp/verify_kernel.img bs=512 skip=$((0x12000)) count=$((0x18000)) status=none
  log "  kernel 分区提取: $(stat -c%s /tmp/verify_kernel.img) bytes"
  python3 - <<'PYEOF'
data = open('/tmp/verify_kernel.img','rb').read(256)
assert data[0:4] == b'KRNL', 'KRNL missing'
code0 = int.from_bytes(data[8:12], 'little')
assert code0 == 0xd503201f, f'code0 not NOP: 0x{code0:08x}'
idx = data.find(b'ARM\x64')
assert idx == 0x40, f'magic at 0x{idx:x}'
print('  ✓ kernel 分区 ARM64 magic at 0x40')
print('  ✓ kernel 分区含 flippy')
PYEOF

  # rootfs 分区偏移 0x4a000 扇区, 大小 0x200000 扇区 (2048 MiB)
  dd if="$raw_img" of=/tmp/verify_rootfs.img bs=512 skip=$((0x4a000)) count=$((0x200000)) status=none
  log "  rootfs 分区提取: $(stat -c%s /tmp/verify_rootfs.img) bytes"
  if ! simg2img /tmp/verify_rootfs.img /tmp/verify_rootfs_raw.img 2>/dev/null; then
    cp /tmp/verify_rootfs.img /tmp/verify_rootfs_raw.img
  fi
  mkdir -p /tmp/verify_rootfs_mnt
  if sudo mount -o loop,ro /tmp/verify_rootfs_raw.img /tmp/verify_rootfs_mnt 2>/dev/null; then
    local mod_name
    mod_name=$(ls /tmp/verify_rootfs_mnt/lib/modules 2>/dev/null | head -1)
    if [ -n "$mod_name" ]; then
      log "  ✓ rootfs 分区含 flippy modules: $mod_name"
    else
      err "  ✗ rootfs 分区缺少 modules"
      sudo umount /tmp/verify_rootfs_mnt
      exit 1
    fi
    df -h /tmp/verify_rootfs_mnt | tail -1
    sudo umount /tmp/verify_rootfs_mnt
  else
    err "  ✗ 无法挂载 rootfs 分区"
    exit 1
  fi
  rm -f /tmp/verify_kernel.img /tmp/verify_rootfs.img /tmp/verify_rootfs_raw.img

  log "✓ 验证通过 (version $VERSION)"
}

case "${1:-}" in
  apply)  shift; cmd_apply "$@" ;;
  verify) shift; cmd_verify "$@" ;;
  *) echo "Usage: $0 {apply|verify} <dir-or-img>"; exit 1 ;;
esac