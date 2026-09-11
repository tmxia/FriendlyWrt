#!/bin/bash
# replace-kernel.sh - Flippy 内核 + 模块注入 + boot.img 重建 → 官方 KRNL 结构
set -euo pipefail

VERSION="2026-09-11-v42-rootfs-partition-expand"
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
# ★★★ 5.4 rootfs 分区大小检查 + 自动扩展 ★★★
# 修复：rootfs.img 是 2GiB，但 parameter.txt 里 rootfs 分区只有 1GiB
#       mk-sd-image.sh 会拒绝写入，导致最终 img 里 rootfs 是空的
# ============================================================
log "[5.4/9] 检查/扩展 rootfs 分区"

ROOTFS_PART=$(grep -oE '0x[0-9a-fA-F]+@0x[0-9a-fA-F]+\(rootfs\)' "$PARAM_FILE" | head -1)
if [ -n "$ROOTFS_PART" ]; then
  PART_SECTORS=$(echo "$ROOTFS_PART" | sed -E 's/0x([0-9a-fA-F]+)@.*/\1/')
  PART_BYTES=$(( 0x$PART_SECTORS * 512 ))
  log "  parameter.txt rootfs 分区: $PART_SECTORS sectors = $PART_BYTES bytes ($((PART_BYTES/1024/1024)) MiB)"
  log "  rootfs raw 大小: $RAW_SIZE_FINAL bytes ($((RAW_SIZE_FINAL/1024/1024)) MiB)"

  if [ "$RAW_SIZE_FINAL" -gt "$PART_BYTES" ]; then
    warn "  ★ rootfs raw ($((RAW_SIZE_FINAL/1024/1024)) MiB) > 分区 ($((PART_BYTES/1024/1024)) MiB)，扩展 parameter.txt"
    python3 - "$PARAM_FILE" "$RAW_SIZE_FINAL" <<'PARAM_EXPAND'
import re, sys
param_file, new_bytes = sys.argv[1], int(sys.argv[2])
content = open(param_file).read()
m = re.search(r'0x([0-9a-fA-F]+)@(0x[0-9a-fA-F]+)\(rootfs\)', content)
old_size = int(m.group(1), 16)
rootfs_off = int(m.group(2), 16)
rootfs_end = rootfs_off + old_size
need = (new_bytes + 511) // 512
rounded = ((need + 0x3FFF) // 0x4000) * 0x4000
new_size = max(rounded, old_size)
if new_size == old_size:
    print("[param] rootfs 无需扩展"); sys.exit(0)
delta = new_size - old_size
print(f"[param] rootfs: {old_size*512/1024/1024:.1f}MiB → {new_size*512/1024/1024:.1f}MiB (delta={delta} sectors)")
# 替换 rootfs size
content = content[:m.start()] + f'0x{new_size:08x}@{m.group(2)}(rootfs)' + content[m.end():]
# 调整 rootfs 之后所有分区的偏移
def shift(mt):
    off = int(mt.group(1), 16)
    return f'@0x{off + delta:08x}' if off >= rootfs_end else mt.group(0)
content = re.sub(r'@0x([0-9a-fA-F]+)', shift, content)
open(param_file, 'w').write(content)
print(f"[param] 后续分区偏移 +{delta} sectors")
PARAM_EXPAND
    log "  ✓ rootfs 分区已扩展"
  else
    log "  ✓ rootfs raw ($RAW_SIZE_FINAL) ≤ 分区 ($PART_BYTES)"
  fi
else
  warn "  parameter.txt 无 rootfs 分区定义"
fi

log "  ✓ rootfs.img 处理完成"

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
print(f"[param] kernel: {old_size*512//1024//1024}→{new_size*512//1024//1024} MiB (delta={delta} sectors)")
PARAM_PYEOF

# 打印最终 parameter.txt 诊断
log "  parameter.txt CMDLINE:"
grep -E '^CMDLINE:' "$PARAM_FILE" | head -1 | sed 's/^/    /'

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
# 6.9 重建 boot.img (KRNL + gzip)
# ============================================================
log ""
log "════════════════════════════════════════════════════════"
log "  ★ [6.9/9] 重建 boot.img (KRNL + gzip)"
log "════════════════════════════════════════════════════════"

BOOT_IMG="$TARGET_DIR/boot.img"
UINITRD_FILE="$TARGET_DIR/uInitrd"

if [ ! -f "$UINITRD_FILE" ]; then
  warn "  uInitrd 不存在，跳过 boot.img 重建"
else
  if [ -f "$BOOT_IMG" ]; then
    cp "$BOOT_IMG" "$WORK_DIR/boot.img.orig" 2>/dev/null || true
    log "  官方 boot.img: $(stat -c%s "$BOOT_IMG") bytes (已备份)"
  fi

  UINITRD_MAGIC=$(dd if="$UINITRD_FILE" bs=1 count=4 2>/dev/null | xxd -p)
  UINITRD_SIZE=$(stat -c%s "$UINITRD_FILE")
  log "  uInitrd: $UINITRD_SIZE bytes, magic=$UINITRD_MAGIC"

  RAW_PAYLOAD=""
  case "$UINITRD_MAGIC" in
    27051956*)
      log "  uInitrd 是 U-Boot legacy image，剥离 64 字节头"
      mkdir -p "$WORK_DIR/boot_extract"
      RAW_PAYLOAD="$WORK_DIR/boot_extract/raw_payload"
      tail -c +65 "$UINITRD_FILE" > "$RAW_PAYLOAD"
      log "  ✓ 提取到 raw payload: $(stat -c%s "$RAW_PAYLOAD") bytes"
      ;;
    1f8b08*)
      log "  uInitrd 是纯 gzip 数据"
      RAW_PAYLOAD="$UINITRD_FILE"
      ;;
    *)
      warn "  uInitrd 未知格式 ($UINITRD_MAGIC)，保留官方 boot.img"
      ;;
  esac

  RAMDISK=""
  if [ -n "$RAW_PAYLOAD" ] && [ -f "$RAW_PAYLOAD" ] && [ -s "$RAW_PAYLOAD" ]; then
    PAYLOAD_MAGIC=$(dd if="$RAW_PAYLOAD" bs=1 count=4 2>/dev/null | xxd -p)
    log "  payload magic: $PAYLOAD_MAGIC"

    case "$PAYLOAD_MAGIC" in
      1f8b08*)
        log "  ✓ payload 已是 gzip，保持"
        RAMDISK="$RAW_PAYLOAD"
        ;;
      fd377a58*)
        log "  ★ payload 是 XZ，转码为 gzip（U-Boot 兼容）..."
        set +e
        unxz -c "$RAW_PAYLOAD" > "$WORK_DIR/boot_extract/raw" 2>/dev/null
        RC1=$?
        set -e
        if [ $RC1 -eq 0 ] && [ -s "$WORK_DIR/boot_extract/raw" ]; then
          RAW_SIZE=$(stat -c%s "$WORK_DIR/boot_extract/raw")
          log "    XZ 解压成功: $RAW_SIZE bytes"
          gzip -9 -c "$WORK_DIR/boot_extract/raw" > "$WORK_DIR/boot_extract/raw.gz"
          GZ_SIZE=$(stat -c%s "$WORK_DIR/boot_extract/raw.gz")
          log "    gzip 压缩完成: $GZ_SIZE bytes"
          RAMDISK="$WORK_DIR/boot_extract/raw.gz"
        else
          warn "    XZ 解压失败"
          RAMDISK="$RAW_PAYLOAD"
        fi
        ;;
      04224d18*)
        log "  ★ payload 是 LZ4，转码为 gzip..."
        set +e
        lz4 -d -c "$RAW_PAYLOAD" > "$WORK_DIR/boot_extract/raw" 2>/dev/null
        RC1=$?
        set -e
        if [ $RC1 -eq 0 ] && [ -s "$WORK_DIR/boot_extract/raw" ]; then
          gzip -9 -c "$WORK_DIR/boot_extract/raw" > "$WORK_DIR/boot_extract/raw.gz"
          RAMDISK="$WORK_DIR/boot_extract/raw.gz"
        else
          warn "    LZ4 解压失败"
          RAMDISK="$RAW_PAYLOAD"
        fi
        ;;
      *)
        warn "  ⚠ 未知压缩格式 ($PAYLOAD_MAGIC)，保留原样"
        RAMDISK="$RAW_PAYLOAD"
        ;;
    esac
  fi

  if [ -n "$RAMDISK" ] && [ -f "$RAMDISK" ] && [ -s "$RAMDISK" ]; then
    DATA_SIZE=$(stat -c%s "$RAMDISK")
    log "  构造 KRNL boot.img (数据 $DATA_SIZE bytes)"

    python3 - "$RAMDISK" "$BOOT_IMG" <<'BOOT_BUILD'
import sys, struct
ramdisk_path = sys.argv[1]
boot_img_path = sys.argv[2]
data = open(ramdisk_path, 'rb').read()
print(f"    数据大小: {len(data)}")
print(f"    数据前 4 字节: {data[:4].hex()}")
size_field = len(data)
hdr = b'KRNL' + struct.pack('<I', size_field)
with open(boot_img_path, 'wb') as f:
    f.write(hdr)
    f.write(data)
    f.write(b'\x00\x00\x00\x00')
print(f"    新 boot.img 总大小: {8 + len(data) + 4}")
BOOT_BUILD

    NEW_SIZE=$(stat -c%s "$BOOT_IMG" 2>/dev/null || echo 0)
    NEW_MAGIC=$(dd if="$BOOT_IMG" bs=1 count=4 2>/dev/null)
    NEW_DATA_MAGIC=$(dd if="$BOOT_IMG" bs=1 skip=8 count=4 2>/dev/null | xxd -p)

    log "  新 boot.img 大小: $NEW_SIZE bytes"
    log "  新 boot.img magic: $NEW_MAGIC"
    log "  新 boot.img payload magic: $NEW_DATA_MAGIC"
    log "  新 boot.img 前 16 字节:"
    xxd -l 16 "$BOOT_IMG" | sed 's/^/    /'

    if [ "$NEW_MAGIC" = "KRNL" ] && { [ "$NEW_DATA_MAGIC" = "1f8b0800" ] || [ "$NEW_DATA_MAGIC" = "1f8b0808" ]; }; then
      log "  ✓ boot.img 重建成功 (payload = gzip)"
    elif [ "$NEW_MAGIC" = "KRNL" ] && [ "$NEW_SIZE" -gt 100000 ]; then
      warn "  ⚠ boot.img 已重建但 payload 非 gzip"
    else
      err "  ✗ 重建失败，恢复官方 boot.img"
      [ -f "$WORK_DIR/boot.img.orig" ] && cp "$WORK_DIR/boot.img.orig" "$BOOT_IMG"
    fi
  else
    warn "  无有效数据源，保留官方 boot.img"
    [ -f "$WORK_DIR/boot.img.orig" ] && cp "$WORK_DIR/boot.img.orig" "$BOOT_IMG"
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

log "  TARGET_DIR 内容（$DIST_NAME）:"
ls -la "$DIST_NAME" | sed 's/^/    /'

set +e
set +o pipefail
yes 2>/dev/null | ./mk-sd-image.sh "$DIST_NAME" > /tmp/mk-sd.log 2>&1
MK_EXIT=$?
set -o pipefail
set -e

log "  ── mk-sd-image.sh 完整输出 ($(wc -l < /tmp/mk-sd.log) 行) ──"
cat /tmp/mk-sd.log | sed 's/^/    /'
log "  ── 输出结束 ──"
log "  mk-sd-image.sh exit=$MK_EXIT"

if ! grep -q "RAW image successfully created" /tmp/mk-sd.log; then
  err "  mk-sd-image.sh 未报告成功"
  exit 1
fi

FOUND_IMG=$(find out -maxdepth 1 -name "*.img" -print -quit)
[ -z "$FOUND_IMG" ] && { err "  无 img"; exit 1; }

FOUND_SIZE=$(stat -c%s "$FOUND_IMG")
log "  img 文件大小: $FOUND_SIZE bytes"

APPARENT=$(du -B1 --apparent-size "$FOUND_IMG" 2>/dev/null | awk '{print $1}')
PHYSICAL=$(du -B1 "$FOUND_IMG" 2>/dev/null | awk '{print $1}')
log "  img 逻辑大小: $APPARENT bytes / 物理占用: $PHYSICAL bytes"

ROOTFS_OFFSET=$(grep -oE '0x[0-9a-fA-F]+@0x[0-9a-fA-F]+\(rootfs\)' "$PARAM_FILE" \
  | head -1 | sed -E 's/.*@(0x[0-9a-fA-F]+)\(rootfs\)/\1/')
if [ -n "$ROOTFS_OFFSET" ]; then
  ROOTFS_BYTE_OFF=$(( ROOTFS_OFFSET * 512 ))
  log "  rootfs 分区 @ $ROOTFS_BYTE_OFF bytes"

  ROOTFS_HEAD_HEX=$(dd if="$FOUND_IMG" bs=1 skip="$ROOTFS_BYTE_OFF" count=1024 2>/dev/null | xxd -p | tr -d '\n')
  NONZERO=$(echo "$ROOTFS_HEAD_HEX" | tr -d '0' | wc -c)
  log "  rootfs 前 1KB 非零字节数: $NONZERO"

  if [ "$NONZERO" -lt 100 ]; then
    err "  ✗ rootfs 分区前 1KB 几乎全零"
    exit 1
  fi

  ROOTFS_MAGIC2=$(dd if="$FOUND_IMG" bs=1 skip=$(( ROOTFS_BYTE_OFF + 0x438 )) count=2 2>/dev/null | xxd -p)
  log "  rootfs 分区 @ +0x438 magic: $ROOTFS_MAGIC2"
  if [ "$ROOTFS_MAGIC2" = "53ef" ]; then
    log "  ✓ rootfs 分区含 ext4 magic"
  fi
fi

mv "$FOUND_IMG" "$OUTPUT_IMG"

# ============================================================
# 8. 最终验证
# ============================================================
log "[8/9] 最终验证"

KERNEL_OFFSET=$(grep -oE '0x[0-9a-fA-F]+@0x[0-9a-fA-F]+\(kernel\)' "$PARAM_FILE" \
  | head -1 | sed -E 's/.*@(0x[0-9a-fA-F]+)\(kernel\)/\1/')
KERNEL_BYTE_OFF=$(( KERNEL_OFFSET * 512 ))
MAGIC=$(dd if="$OUTPUT_IMG" bs=1 skip="$KERNEL_BYTE_OFF" count=4 2>/dev/null)
[ "$MAGIC" != "KRNL" ] && { err "  KNL magic 缺失"; exit 1; }
log "  ✓ kernel KNL magic @ $KERNEL_BYTE_OFF"

BOOT_OFFSET=$(grep -oE '0x[0-9a-fA-F]+@0x[0-9a-fA-F]+\(boot\)' "$PARAM_FILE" \
  | head -1 | sed -E 's/.*@(0x[0-9a-fA-F]+)\(boot\)/\1/')
if [ -n "$BOOT_OFFSET" ]; then
  BOOT_BYTE_OFF=$(( BOOT_OFFSET * 512 ))
  BOOT_MAGIC_HEX=$(dd if="$OUTPUT_IMG" bs=1 skip="$BOOT_BYTE_OFF" count=4 2>/dev/null | xxd -p)
  BOOT_DATA_HEX=$(dd if="$OUTPUT_IMG" bs=1 skip=$(( BOOT_BYTE_OFF + 8 )) count=4 2>/dev/null | xxd -p)
  log "  boot 分区 @ $BOOT_BYTE_OFF: magic=$BOOT_MAGIC_HEX, payload=$BOOT_DATA_HEX"
  if [ "$BOOT_MAGIC_HEX" = "4b524e4c" ] && { [ "$BOOT_DATA_HEX" = "1f8b0800" ] || [ "$BOOT_DATA_HEX" = "1f8b0808" ]; }; then
    log "  ✓ boot 分区 KRNL + gzip 正确"
  fi
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