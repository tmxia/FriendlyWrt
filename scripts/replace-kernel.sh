#!/bin/bash
# replace-kernel.sh - Flippy 内核 + 模块注入 + boot.img 重建 → 官方 KRNL 结构
set -euo pipefail

VERSION="2026-09-11-v38-bootimg-args-fix"
log()  { echo -e "\033[0;32m[replace]\033[0m $*"; }
warn() { echo -e "\033[0;33m[replace]\033[0m $*"; }
err()  { echo -e "\033[0;31m[replace]\033[0m $*" >&2; }
log "replace-kernel.sh version: $VERSION"

IMAGES_TGZ="${1:?}"; SDFUSE_DIR="${2:?}"; DIST_NAME="${3:?}"; OUTPUT_IMG="${4:?}"
KERNEL_VERSION="${KERNEL_VERSION:-6.18.y}"
OFFICIAL_DIR="${OFFICIAL_DIR:-/tmp/official}"

WORK_DIR=$(mktemp -d /tmp/replace-kernel.XXXXXX)

_cleanup() {
  _rc=$?
  for m in "$WORK_DIR/mnt" /tmp/fwrt-mnt-*; do
    if [ -d "$m" ] && mountpoint -q "$m" 2>/dev/null; then
      sudo umount -f "$m" 2>/dev/null || umount -f "$m" 2>/dev/null || true
    fi
  done
  sudo rm -rf "$WORK_DIR" 2>/dev/null
  if [ -d "$WORK_DIR" ]; then rm -rf "$WORK_DIR" 2>/dev/null || true; fi
  exit $_rc
}
trap _cleanup EXIT

# ============================================================
# 1. 解压 images.tgz
# ============================================================
log "[1/9] 解压 images.tgz"
mkdir -p "$WORK_DIR/base"
tar xzf "$IMAGES_TGZ" -C "$WORK_DIR/base"
BASE_DIR=$(find "$WORK_DIR/base" -maxdepth 2 -type d -name "friendlywrt*" | head -1)
[ -z "$BASE_DIR" ] && { err "找不到顶层目录"; exit 1; }

# ============================================================
# 2. 扫描内核
# ============================================================
log "[2/9] 扫描 $KERNEL_VERSION"
case "$KERNEL_VERSION" in
  6.18*|6.18.y) PREFIX="6.18" ;;
  6.12*|6.12.y) PREFIX="6.12" ;;
  6.6*|6.6.y)   PREFIX="6.6" ;;
  6.1*|6.1.y)   PREFIX="6.1" ;;
  auto|"")      PREFIX="" ;;
  *)            PREFIX="$KERNEL_VERSION" ;;
esac

declare -A VER_TO_SOURCE
for target in \
  "ophub/kernel:kernel_flippy" \
  "ophub/kernel:kernel_rk35xx" \
  "breakingbadboy/OpenWrt:kernel_rk35xx"; do
  REPO="${target%%:*}"; RELEASE="${target##*:}"
  ASSETS=$(gh release view "$RELEASE" --repo "$REPO" --json assets --jq '.assets[].name' 2>/dev/null || echo "")
  [ -z "$ASSETS" ] && continue
  if [ -n "$PREFIX" ]; then
    VERS=$(echo "$ASSETS" | grep -E "^${PREFIX}\.[0-9]+\.tar\.gz$" | sed 's/\.tar\.gz//' | sort -V || echo "")
  else
    VERS=$(echo "$ASSETS" | grep -E '^6\.[0-9]+\.[0-9]+\.tar\.gz$' | sed 's/\.tar\.gz//' | sort -V || echo "")
  fi
  [ -z "$VERS" ] && continue
  for v in $VERS; do
    [ -z "${VER_TO_SOURCE[$v]:-}" ] && VER_TO_SOURCE["$v"]="$REPO:$RELEASE"
  done
done
[ ${#VER_TO_SOURCE[@]} -eq 0 ] && { err "无匹配内核"; exit 1; }
SELECTED_VER=$(printf '%s\n' "${!VER_TO_SOURCE[@]}" | sort -V | tail -1)
SELECTED_SOURCE="${VER_TO_SOURCE[$SELECTED_VER]}"
SELECTED_REPO="${SELECTED_SOURCE%%:*}"; SELECTED_RELEASE="${SELECTED_SOURCE##*:}"
log "  选中: $SELECTED_VER ($SELECTED_REPO/$SELECTED_RELEASE)"

# ============================================================
# 3. 下载内核
# ============================================================
log "[3/9] 下载内核"
KERNEL_CACHE="/tmp/kernel-cache-${SELECTED_RELEASE}/${SELECTED_VER}"
if [ ! -f "$KERNEL_CACHE/.ready" ]; then
  rm -rf "$KERNEL_CACHE"; mkdir -p "$KERNEL_CACHE"; cd "$KERNEL_CACHE"
  URL="https://github.com/${SELECTED_REPO}/releases/download/${SELECTED_RELEASE}/${SELECTED_VER}.tar.gz"
  log "  URL: $URL"
  wget -q --timeout=120 --tries=2 "$URL" -O kernel.tar.gz 2>/dev/null \
    || curl -L -f --max-time 300 "$URL" -o kernel.tar.gz
  tar xzf kernel.tar.gz
  LOCAL_KDIR="$SELECTED_VER"
  [ ! -d "$LOCAL_KDIR" ] && LOCAL_KDIR=$(find . -maxdepth 2 -type d -name "*${SELECTED_VER}*" \
    ! -path "./boot*" ! -path "./dtb*" ! -path "./modules*" | head -1)
  echo "$KERNEL_CACHE/$LOCAL_KDIR" > .topdir
  for type in boot dtb modules; do
    TAR=$(find "$LOCAL_KDIR" -maxdepth 1 -name "${type}-*.tar.gz" | head -1)
    [ -z "$TAR" ] && [ "$type" = "dtb" ] && \
      TAR=$(find "$LOCAL_KDIR" -maxdepth 1 -name "dtb-rockchip-*.tar.gz" | head -1)
    [ -n "$TAR" ] && tar xzf "$TAR" -C "$KERNEL_CACHE" && log "  ✓ $type"
  done
  touch .ready
fi
KERNEL_TOPDIR=$(cat "$KERNEL_CACHE/.topdir")

# ============================================================
# 4. 复制骨架
# ============================================================
log "[4/9] 复制骨架"
TARGET_DIR="$SDFUSE_DIR/$DIST_NAME"
rm -rf "$TARGET_DIR"
cp -a "$BASE_DIR" "$TARGET_DIR"

# ============================================================
# 5. KRNL 构造
# ============================================================
log "[5/9] 构造 kernel.img"

IMAGE_FILE=$(find "$KERNEL_CACHE" -maxdepth 3 -type f -name "vmlinuz-*" | head -1)
[ -z "$IMAGE_FILE" ] && IMAGE_FILE=$(find "$KERNEL_CACHE" -maxdepth 3 -type f -name "Image*" | head -1)
[ -z "$IMAGE_FILE" ] && { err "找不到内核 Image"; exit 1; }
log "  文件: $(basename "$IMAGE_FILE") ($(stat -c%s "$IMAGE_FILE") bytes)"

SYSTEM_MAP=$(find "$KERNEL_CACHE" -maxdepth 3 -type f -name "System.map-*" | head -1)
[ -z "$SYSTEM_MAP" ] && { err "无 System.map"; exit 1; }

OFFICIAL_PAYLOAD="$WORK_DIR/official_krnl.bin"
OFFICIAL_IMG=$(find "$OFFICIAL_DIR" -maxdepth 1 -name "*.img" 2>/dev/null | head -1 || true)
if [ -n "$OFFICIAL_IMG" ] && [ -f "$OFFICIAL_IMG" ]; then
  python3 - "$OFFICIAL_IMG" "$OFFICIAL_PAYLOAD" <<'EXTRACT' || true
import sys
img, out = sys.argv[1], sys.argv[2]
with open(img, 'rb') as f:
    buf = f.read(64 * 1024 * 1024)
idx = buf.find(b'KRNL')
if idx >= 0:
    end = min(len(buf), idx + 64 * 1024 * 1024)
    open(out, 'wb').write(buf[idx:end])
else:
    sys.exit(1)
EXTRACT
fi

python3 - "$IMAGE_FILE" "$TARGET_DIR/kernel.img" "$OFFICIAL_PAYLOAD" "$SYSTEM_MAP" <<'PYEOF'
import sys, struct, os

src, dst = sys.argv[1], sys.argv[2]
sysmap_path = sys.argv[4] if len(sys.argv) > 4 and sys.argv[4] else None
raw = open(src, 'rb').read()

if raw[:4] == b'KRNL':
    open(dst, 'wb').write(raw); sys.exit(0)
if raw[:2] != b'MZ':
    idx = raw.find(b'ARM\x64')
    if idx == 0x38 and raw[0:4] == b'\x1f\x20\x03\xd5':
        open(dst, 'wb').write(b'KRNL' + struct.pack('<I', len(raw)) + raw)
        sys.exit(0)
    sys.exit(1)

pe_off = struct.unpack_from('<I', raw, 0x3C)[0]
coff = pe_off + 4
nsec = struct.unpack_from('<H', raw, coff + 2)[0]
opt_size = struct.unpack_from('<H', raw, coff + 16)[0]
sec_base = coff + 20 + opt_size

secs = []
for i in range(nsec):
    o = sec_base + i * 40
    name  = raw[o:o+8].rstrip(b'\x00').decode('ascii', 'ignore')
    vsize = struct.unpack_from('<I', raw, o + 8)[0]
    vaddr = struct.unpack_from('<I', raw, o + 12)[0]
    rsize = struct.unpack_from('<I', raw, o + 16)[0]
    roff  = struct.unpack_from('<I', raw, o + 20)[0]
    secs.append(dict(name=name, vaddr=vaddr, vsize=vsize, rsize=rsize, roff=roff))

text_s = next(s for s in secs if s['name'] == '.text')
text = raw[text_s['roff']: text_s['roff'] + text_s['rsize']]
text_roff = text_s['roff']
payload_tail = raw[text_s['roff']:]

syms = {}
with open(sysmap_path, 'r', errors='ignore') as f:
    for line in f:
        parts = line.split()
        if len(parts) < 3: continue
        try:
            addr = int(parts[0], 16)
        except ValueError:
            continue
        if parts[2] not in syms:
            syms[parts[2]] = addr

_text  = syms.get('_text')
primary = syms.get('primary_entry')
rec_mmu = syms.get('record_mmu_state')

def v2p(vaddr): return vaddr - _text - text_roff

REC_PATTERN = b'\x53\x42\x38\xd5\x7f\x22\x00\xf1'
rec_feature = text.find(REC_PATTERN)
rec_off = rec_feature if rec_feature >= 0 else (v2p(rec_mmu) if rec_mmu else None)

def insn_at(off):
    if off < 0 or off + 4 > len(text): return None
    return struct.unpack_from('<I', text, off)[0]
def is_bl(v): return v is not None and ((v >> 26) & 0x3F) == 0x25
def bl_target(off):
    v = insn_at(off)
    if not is_bl(v): return None
    imm = v & 0x03FFFFFF
    if imm & 0x02000000: imm -= 0x04000000
    return off + imm * 4

entry = None
entry_method = None

if primary:
    e = v2p(primary)
    if 0 <= e < len(text) - 16 and any(text[e:e+16]):
        first = insn_at(e)
        op = (first >> 26) & 0x3F
        if op == 0x25 and rec_off is not None:
            if bl_target(e) == rec_off:
                entry = e
                entry_method = "System.map primary_entry (BL→record_mmu)"
        elif op in (0x25, 0x05):
            entry = e
            entry_method = "System.map primary_entry"

if entry is None and rec_off is not None:
    for i in range(max(0, rec_off - 0x200), rec_off, 4):
        if bl_target(i) == rec_off:
            if sum(1 for k in range(4) if is_bl(insn_at(i + k*4))) >= 2:
                entry = i
                entry_method = "BL 反查"
                break

if entry is None: sys.exit(1)

KNL_HDR = 0x10000
target_in_knl = KNL_HDR + entry
rel = target_in_knl - 0x0C
code1 = 0x14000000 | ((rel // 4) & 0x03FFFFFF)

hdr = bytearray(KNL_HDR)
struct.pack_into('<I', hdr, 0x00, 0x4c4e524b)
struct.pack_into('<I', hdr, 0x04, KNL_HDR + len(payload_tail))
struct.pack_into('<I', hdr, 0x08, 0xd503201f)
struct.pack_into('<I', hdr, 0x0C, code1)
struct.pack_into('<Q', hdr, 0x10, 0)
struct.pack_into('<Q', hdr, 0x18, len(payload_tail))
struct.pack_into('<Q', hdr, 0x20, 0x0a)
hdr[0x40:0x44] = b'ARMd'

knl = bytes(hdr) + payload_tail
open(dst, 'wb').write(knl)

assert knl[0:4] == b'KRNL'
assert not any(knl[0x48:0x10000])
print("  KNL size=%d  entry=0x%x  方法=%s" % (len(knl), entry, entry_method))
PYEOF

KERNEL_IMG="$TARGET_DIR/kernel.img"
[ "$(dd if="$KERNEL_IMG" bs=1 count=4 2>/dev/null)" != "KRNL" ] && { err "kernel.img 头部不是 KRNL"; exit 1; }
log "  ✓ kernel.img KNL magic 通过 ($(stat -c%s "$KERNEL_IMG") bytes)"

# ============================================================
# 5.3 注入内核模块
# ============================================================
log "[5.3/9] 注入内核模块到 rootfs.img"

MODULES_TAR=$(find "$KERNEL_CACHE" -maxdepth 2 -name "modules-*.tar.gz" | head -1)
ROOTFS_IMG="$TARGET_DIR/rootfs.img"
PARAM_FILE="$TARGET_DIR/parameter.txt"

[ -z "$MODULES_TAR" ] && { err "  未找到 modules-*.tar.gz"; exit 1; }
[ ! -f "$ROOTFS_IMG" ] && { err "  rootfs.img 不存在"; exit 1; }
[ ! -f "$PARAM_FILE" ] && { err "  parameter.txt 不存在"; exit 1; }

MOD_EX="$WORK_DIR/modules_extract"
mkdir -p "$MOD_EX"
tar xzf "$MODULES_TAR" -C "$MOD_EX"
MOD_LIB=$(find "$MOD_EX" -maxdepth 5 -type d -path "*/lib/modules/6.*" | head -1)
[ -z "$MOD_LIB" ] && MOD_LIB=$(find "$MOD_EX" -maxdepth 5 -type d -name "6.*" | head -1)
[ -z "$MOD_LIB" ] && { err "  模块目录未找到"; exit 1; }
KVER=$(basename "$MOD_LIB")
KO_COUNT=$(find "$MOD_LIB" -name "*.ko*" 2>/dev/null | wc -l)
log "  内核: $KVER  模块数: $KO_COUNT"

ORIG_FMT=$(file -b "$ROOTFS_IMG")
WORK_ROOTFS=""
IS_SPARSE=0
if echo "$ORIG_FMT" | grep -qi "Android sparse"; then
  WORK_ROOTFS="$WORK_DIR/rootfs.raw"
  simg2img "$ROOTFS_IMG" "$WORK_ROOTFS"
  IS_SPARSE=1
else
  cp "$ROOTFS_IMG" "$WORK_ROOTFS"
fi

RAW_FMT=$(file -b "$WORK_ROOTFS")

if echo "$RAW_FMT" | grep -qi "squashfs"; then
  command -v unsquashfs >/dev/null || { err "  缺少 unsquashfs"; exit 1; }
  command -v mksquashfs >/dev/null || { err "  缺少 mksquashfs"; exit 1; }
  COMP=$(unsquashfs -s "$WORK_ROOTFS" 2>/dev/null | grep -i 'compression' | awk '{print tolower($2)}')
  [ -z "$COMP" ] && COMP="xz"
  case "$COMP" in
    gzip) MK_COMP="-comp gzip" ;; lzo) MK_COMP="-comp lzo" ;;
    lz4)  MK_COMP="-comp lz4"  ;; xz)  MK_COMP="-comp xz"  ;;
    zstd) MK_COMP="-comp zstd" ;; *)   MK_COMP="-comp xz"  ;;
  esac
  ROOT_EX="$WORK_DIR/rootfs_extract"
  mkdir -p "$ROOT_EX"
  unsquashfs -d "$ROOT_EX" -no-progress "$WORK_ROOTFS" > /dev/null 2>&1
  rm -rf "$ROOT_EX/lib/modules/"*
  mkdir -p "$ROOT_EX/lib/modules/$KVER"
  cp -a "$MOD_LIB/." "$ROOT_EX/lib/modules/$KVER/"
  ROOTFS_NEW_RAW="$WORK_DIR/rootfs.new.raw"
  mksquashfs "$ROOT_EX" "$ROOTFS_NEW_RAW" $MK_COMP -b 128K -noappend -no-progress > /dev/null 2>&1
  mv "$ROOTFS_NEW_RAW" "$WORK_ROOTFS"
elif echo "$RAW_FMT" | grep -qiE "ext[234]|Linux.*ext"; then
  CURRENT_RAW=$(stat -c%s "$WORK_ROOTFS")
  TARGET_RAW=$(( 2 * 1024 * 1024 * 1024 ))
  if [ "$CURRENT_RAW" -lt "$TARGET_RAW" ]; then
    truncate -s "$TARGET_RAW" "$WORK_ROOTFS"
    sudo e2fsck -f -y "$WORK_ROOTFS" > /dev/null 2>&1 || true
    sudo resize2fs "$WORK_ROOTFS" > /dev/null 2>&1 || true
  fi
  MNT="$WORK_DIR/mnt"
  mkdir -p "$MNT"
  sudo mount -o loop,rw "$WORK_ROOTFS" "$MNT" 2>/dev/null || sudo mount -t ext4 -o loop,rw "$WORK_ROOTFS" "$MNT"
  sudo rm -rf "$MNT/lib/modules/"*
  sync
  sudo mkdir -p "$MNT/lib/modules/$KVER"
  sudo cp -a "$MOD_LIB/." "$MNT/lib/modules/$KVER/"
  sync
  INJECTED=$(sudo find "$MNT/lib/modules/$KVER" -name '*.ko*' | wc -l)
  log "  已注入: $INJECTED / $KO_COUNT"
  sudo umount -f "$MNT" 2>/dev/null || true
else
  err "  不支持格式: $RAW_FMT"; exit 1
fi

if [ "$IS_SPARSE" = "1" ]; then
  ROOTFS_FINAL="$WORK_DIR/rootfs.final.img"
  img2simg "$WORK_ROOTFS" "$ROOTFS_FINAL" 4096
  RAW_SIZE_FINAL=$(stat -c%s "$WORK_ROOTFS")
  mv "$ROOTFS_FINAL" "$ROOTFS_IMG"
else
  RAW_SIZE_FINAL=$(stat -c%s "$WORK_ROOTFS")
  mv "$WORK_ROOTFS" "$ROOTFS_IMG"
fi

# ============================================================
# 5.5 扩容 kernel 分区
# ============================================================
log "[5.5/9] 扩容 kernel 分区"
python3 - "$PARAM_FILE" "$(stat -c%s "$TARGET_DIR/kernel.img")" <<'PARAM_PYEOF'
import re, sys
param_file, kernel_size = sys.argv[1], int(sys.argv[2])
content = open(param_file).read()
m = re.search(r'0x([0-9a-fA-F]+)@(0x[0-9a-fA-F]+)\(kernel\)', content, re.IGNORECASE)
old_size = int(m.group(1), 16)
kernel_off = int(m.group(2), 16)
kernel_end = kernel_off + old_size
need = (kernel_size + 511) // 512
rounded = ((need + 0x3FFF) // 0x4000) * 0x4000
new_size = max(rounded, old_size)
if new_size == old_size: sys.exit(0)
delta = new_size - old_size
content = content[:m.start()] + f'0x{new_size:08x}@{m.group(2)}(kernel)' + content[m.end():]
def shift(mt):
    off = int(mt.group(1), 16)
    return f'@0x{off + delta:08x}' if off >= kernel_end else mt.group(0)
content = re.sub(r'@0x([0-9a-fA-F]+)', shift, content)
open(param_file, 'w').write(content)
print(f"[param] kernel: {old_size*512//1024//1024}→{new_size*512//1024//1024} MiB")
PARAM_PYEOF

# ============================================================
# 6. dtb + uInitrd
# ============================================================
log "[6/9] dtb + uInitrd"
DTB_TAR=$(find "$KERNEL_CACHE" -maxdepth 2 -name "dtb-rockchip-*.tar.gz" | head -1)
if [ -n "$DTB_TAR" ]; then
  mkdir -p "$TARGET_DIR/dtb/rockchip"
  for board in r5s r5c; do
    ENTRY=$(tar tzf "$DTB_TAR" | grep -E "(^|/)rk3568-nanopi-${board}\.dtb$" | head -1 || echo "")
    if [ -n "$ENTRY" ]; then
      tar xzf "$DTB_TAR" -C "$WORK_DIR" "$ENTRY"
      cp "$WORK_DIR/$ENTRY" "$TARGET_DIR/dtb/rockchip/rk3568-nanopi-${board}.dtb"
      log "  ✓ $board dtb"
    fi
  done
fi
UINITRD=$(find "$KERNEL_CACHE" -type f -name "uInitrd-*" | head -1)
if [ -n "$UINITRD" ]; then
  cp "$UINITRD" "$TARGET_DIR/uInitrd"
  log "  ✓ uInitrd ($(stat -c%s "$TARGET_DIR/uInitrd") bytes)"
fi

# ============================================================
# ★★★ 6.9 重建 boot.img ★★★
# 修复: build-boot-img.sh 需要 2 个参数
#   用法: ./build-boot-img.sh <boot dir> <img filename>
#   例:   ./build-boot-img.sh friendlywrt24-docker friendlywrt24-docker/boot.img
# ============================================================
log ""
log "════════════════════════════════════════════════════════"
log "  ★ [6.9/9] 重建 boot.img (调用官方 build-boot-img.sh)"
log "════════════════════════════════════════════════════════"

BOOT_IMG_OLD_SIZE=$(stat -c%s "$TARGET_DIR/boot.img" 2>/dev/null || echo 0)
BOOT_IMG_OLD_MD5=$(md5sum "$TARGET_DIR/boot.img" 2>/dev/null | awk '{print $1}' || echo "N/A")
log "  旧 boot.img 大小: $BOOT_IMG_OLD_SIZE bytes"
log "  旧 boot.img md5:  $BOOT_IMG_OLD_MD5"
log "  旧 boot.img 前 16 字节:"
xxd -l 16 "$TARGET_DIR/boot.img" 2>/dev/null | sed 's/^/    /' || echo "    (无)"

cd "$SDFUSE_DIR"

if [ -x ./build-boot-img.sh ]; then
  # 删除旧的 boot.img（防止脚本因文件存在而跳过）
  log "  ▶ 删除旧 boot.img"
  rm -f "$DIST_NAME/boot.img"

  log "  ▶ 调用 ./build-boot-img.sh $DIST_NAME $DIST_NAME/boot.img"
  set +e
  ./build-boot-img.sh "$DIST_NAME" "$DIST_NAME/boot.img" > "$WORK_DIR/build-boot.log" 2>&1
  BOOT_RC=$?
  set -e
  log "  build-boot-img.sh exit=$BOOT_RC"
  log "  ── 输出 ──"
  cat "$WORK_DIR/build-boot.log" | sed 's/^/    /'
  log "  ── 输出结束 ──"

  if [ ! -f "$DIST_NAME/boot.img" ]; then
    err "  ✗ build-boot-img.sh 执行后 boot.img 仍不存在"
    exit 1
  fi
else
  err "  ✗ build-boot-img.sh 不存在或不可执行"
  exit 1
fi

if [ -f "$TARGET_DIR/boot.img" ]; then
  NEW_BOOT_SIZE=$(stat -c%s "$TARGET_DIR/boot.img")
  NEW_BOOT_MD5=$(md5sum "$TARGET_DIR/boot.img" | awk '{print $1}')
  log "  新 boot.img 大小: $NEW_BOOT_SIZE bytes (旧: $BOOT_IMG_OLD_SIZE)"
  log "  新 boot.img md5:  $NEW_BOOT_MD5"
  log "  新 boot.img 前 32 字节:"
  xxd -l 32 "$TARGET_DIR/boot.img" | sed 's/^/    /'

  if [ "$NEW_BOOT_SIZE" != "$BOOT_IMG_OLD_SIZE" ]; then
    log "  ✓ boot.img 已更新（大小变化）"
  elif [ "$NEW_BOOT_MD5" != "$BOOT_IMG_OLD_MD5" ]; then
    log "  ✓ boot.img 已更新（md5 变化，大小相同）"
  else
    warn "  ⚠ boot.img 未变化 —— 请检查 build-boot-img.sh 输出"
  fi
fi

log "════════════════════════════════════════════════════════"
log ""

# ============================================================
# 7. 生成镜像
# ============================================================
log "[7/9] 生成镜像"
cd "$SDFUSE_DIR"
chmod +x mk-sd-image.sh
rm -f out/*.img /tmp/mk-sd.log

set +e
set +o pipefail
yes 2>/dev/null | ./mk-sd-image.sh "$DIST_NAME" > /tmp/mk-sd.log 2>&1
set -o pipefail
set -e

if ! grep -q "RAW image successfully created" /tmp/mk-sd.log; then
  err "  mk-sd-image.sh 未成功"
  tail -30 /tmp/mk-sd.log | sed 's/^/    /'
  exit 1
fi

FOUND_IMG=$(find out -maxdepth 1 -name "*.img" -print -quit)
[ -z "$FOUND_IMG" ] && { err "  无 img"; exit 1; }
log "  镜像: $FOUND_IMG ($(stat -c%s "$FOUND_IMG") bytes)"

mv "$FOUND_IMG" "$OUTPUT_IMG"

# ============================================================
# 8. 最终验证
# ============================================================
log "[8/9] 最终验证"

KERNEL_OFFSET=$(grep -oE '0x[0-9a-fA-F]+@0x[0-9a-fA-F]+\(kernel\)' "$PARAM_FILE" \
  | head -1 | sed -E 's/.*@(0x[0-9a-fA-F]+)\(kernel\)/\1/')
KERNEL_BYTE_OFF=$(( KERNEL_OFFSET * 512 ))
MAGIC=$(dd if="$OUTPUT_IMG" bs=1 skip=$KERNEL_BYTE_OFF count=4 2>/dev/null)
[ "$MAGIC" != "KRNL" ] && { err "  KNL magic 缺失"; exit 1; }
log "  ✓ KNL magic @ $KERNEL_BYTE_OFF"

# 验证 boot 分区的 boot.img
BOOT_OFFSET=$(grep -oE '0x[0-9a-fA-F]+@0x[0-9a-fA-F]+\(boot\)' "$PARAM_FILE" \
  | head -1 | sed -E 's/.*@(0x[0-9a-fA-F]+)\(boot\)/\1/')
if [ -n "$BOOT_OFFSET" ]; then
  BOOT_BYTE_OFF=$(( BOOT_OFFSET * 512 ))
  BOOT_MAGIC=$(dd if="$OUTPUT_IMG" bs=1 skip=$BOOT_BYTE_OFF count=4 2>/dev/null)
  log "  boot 分区 @ $BOOT_BYTE_OFF: magic=$(printf '%s' "$BOOT_MAGIC" | xxd -p)"
fi

# ============================================================
# 9. 汇总
# ============================================================
log "[9/9] 汇总"
log "  resource.img: $(stat -c%s "$TARGET_DIR/resource.img" 2>/dev/null || echo 'N/A')"
log "  kernel.img:   $(stat -c%s "$TARGET_DIR/kernel.img")"
log "  boot.img:     $(stat -c%s "$TARGET_DIR/boot.img" 2>/dev/null || echo 'N/A')"
log "  rootfs.img:   $(stat -c%s "$TARGET_DIR/rootfs.img")"
log "  uInitrd:      $(stat -c%s "$TARGET_DIR/uInitrd" 2>/dev/null || echo 'N/A')"

log ""
log "完成 (version $VERSION, 内核 $SELECTED_VER)"