#!/bin/bash
# replace-kernel.sh - 内核替换 + 模块注入 + boot.img 重建 + 全面静态验证 + resource.img 诊断
set -euo pipefail

VERSION="2026-09-11-v47-resource-diagnose"
log()  { echo -e "\033[0;32m[replace]\033[0m $*"; }
warn() { echo -e "\033[0;33m[replace]\033[0m $*"; }
err()  { echo -e "\033[0;31m[replace]\033[0m $*" >&2; }
log "replace-kernel.sh version: $VERSION"

IMAGES_TGZ="${1:?}"; SDFUSE_DIR="${2:?}"; DIST_NAME="${3:?}"; OUTPUT_IMG="${4:?}"
KERNEL_VERSION="${KERNEL_VERSION:-6.18.y}"
OFFICIAL_DIR="${OFFICIAL_DIR:-/tmp/official}"

WORK_DIR=$(mktemp -d /tmp/replace-kernel.XXXXXX)
VERIFY_FAIL=0

_cleanup() {
  _rc=$?
  for m in "$WORK_DIR/mnt" "$WORK_DIR/rootfs_check" /tmp/fwrt-mnt-*; do
    if [ -d "$m" ] && mountpoint -q "$m" 2>/dev/null; then
      sudo umount -f "$m" 2>/dev/null || true
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
# 2. 扫描内核（RK35xx 优先，Flippy 备用）
# ============================================================
log "[2/9] 扫描 $KERNEL_VERSION"
SCAN_REPOS=(
  "ophub/kernel:kernel_rk35xx"
  "breakingbadboy/OpenWrt:kernel_rk35xx"
  "breakingbadboy/OpenWrt:kernel_stable"
  "ophub/kernel:kernel_flippy"
)

case "$KERNEL_VERSION" in
  6.18*|6.18.y) PREFIX="6.18" ;;
  6.12*|6.12.y) PREFIX="6.12" ;;
  6.6*|6.6.y)   PREFIX="6.6" ;;
  6.1*|6.1.y)   PREFIX="6.1" ;;
  auto|"")      PREFIX="" ;;
  *)            PREFIX="$KERNEL_VERSION" ;;
esac

declare -A VER_TO_SOURCE
for target in "${SCAN_REPOS[@]}"; do
  REPO="${target%%:*}"; RELEASE="${target##*:}"
  log "  扫描 $REPO / $RELEASE ..."
  ASSETS=$(gh release view "$RELEASE" --repo "$REPO" --json assets --jq '.assets[].name' 2>/dev/null || echo "")
  [ -z "$ASSETS" ] && { log "    (无资产)"; continue; }
  if [ -n "$PREFIX" ]; then
    VERS=$(echo "$ASSETS" | grep -E "^${PREFIX}\.[0-9]+\.tar\.gz$" | sed 's/\.tar\.gz//' | sort -V || echo "")
  else
    VERS=$(echo "$ASSETS" | grep -E '^6\.[0-9]+\.[0-9]+\.tar\.gz$' | sed 's/\.tar\.gz//' | sort -V || echo "")
  fi
  [ -z "$VERS" ] && { log "    (无匹配版本)"; continue; }
  echo "$VERS" | sed 's/^/      /'
  for v in $VERS; do
    [ -z "${VER_TO_SOURCE[$v]:-}" ] && VER_TO_SOURCE["$v"]="$REPO:$RELEASE"
  done
done
[ ${#VER_TO_SOURCE[@]} -eq 0 ] && { err "无匹配内核"; exit 1; }

SELECTED_VER=""
SELECTED_SOURCE=""
for v in $(printf '%s\n' "${!VER_TO_SOURCE[@]}" | sort -V -r); do
  src="${VER_TO_SOURCE[$v]}"
  rel="${src##*:}"
  if [ "$rel" = "kernel_rk35xx" ]; then
    SELECTED_VER="$v"; SELECTED_SOURCE="$src"; break
  fi
done
if [ -z "$SELECTED_VER" ]; then
  SELECTED_VER=$(printf '%s\n' "${!VER_TO_SOURCE[@]}" | sort -V | tail -1)
  SELECTED_SOURCE="${VER_TO_SOURCE[$SELECTED_VER]}"
  warn "  ⚠ 无 RK35xx 内核，退化到 ${SELECTED_SOURCE##*:}"
fi
SELECTED_REPO="${SELECTED_SOURCE%%:*}"; SELECTED_RELEASE="${SELECTED_SOURCE##*:}"
log "  ★ 选中: $SELECTED_VER (来自 $SELECTED_REPO / $SELECTED_RELEASE)"

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
# 5.2 内核内容验证
# ============================================================
log ""
log "════════════════════════════════════════════════════════"
log "  ★ [5.2/9] 内核内容验证"
log "════════════════════════════════════════════════════════"

count_matches() {
  local file="$1" pattern="$2"
  strings -a "$file" 2>/dev/null | grep -c "$pattern" || echo 0
}

RK3568_CNT=$(count_matches "$KERNEL_IMG" "rk3568")
ROCKCHIP_CNT=$(count_matches "$KERNEL_IMG" "rockchip")
KERNEL_VER_STR=$(strings -a "$KERNEL_IMG" 2>/dev/null | grep -oE "Linux version [0-9]+\.[0-9]+\.[0-9]+[^ ]*" | head -1 || echo "")

log "  'rk3568':    $RK3568_CNT 处"
log "  'rockchip':  $ROCKCHIP_CNT 处"
log "  Linux 版本:  ${KERNEL_VER_STR:-(未找到)}"

[ "$RK3568_CNT" -eq 0 ] && { err "内核不含 rk3568 字符串"; exit 1; }
log "  ✓ 内核支持 RK3568"
log ""

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
# 5.4 rootfs 分区大小检查
# ============================================================
log "[5.4/9] 检查/扩展 rootfs 分区"

ROOTFS_PART=$(grep -oE '0x[0-9a-fA-F]+@0x[0-9a-fA-F]+\(rootfs\)' "$PARAM_FILE" | head -1)
if [ -n "$ROOTFS_PART" ]; then
  PART_SECTORS=$(echo "$ROOTFS_PART" | sed -E 's/0x([0-9a-fA-F]+)@.*/\1/')
  PART_BYTES=$(( 0x$PART_SECTORS * 512 ))
  log "  rootfs 分区: $((PART_BYTES/1024/1024)) MiB / raw: $((RAW_SIZE_FINAL/1024/1024)) MiB"

  if [ "$RAW_SIZE_FINAL" -gt "$PART_BYTES" ]; then
    warn "  ★ 扩展 rootfs 分区"
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
if new_size == old_size: sys.exit(0)
delta = new_size - old_size
print(f"[param] rootfs: {old_size*512/1024/1024:.1f}→{new_size*512/1024/1024:.1f} MiB")
content = content[:m.start()] + f'0x{new_size:08x}@{m.group(2)}(rootfs)' + content[m.end():]
def shift(mt):
    off = int(mt.group(1), 16)
    return f'@0x{off + delta:08x}' if off >= rootfs_end else mt.group(0)
content = re.sub(r'@0x([0-9a-fA-F]+)', shift, content)
open(param_file, 'w').write(content)
PARAM_EXPAND
  fi
fi
log "  ✓ rootfs 处理完成"

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
print(f"[param] kernel: {old_size*512//1024//1024}→{new_size*512//1024//1024} MiB")
content = content[:m.start()] + f'0x{new_size:08x}@{m.group(2)}(kernel)' + content[m.end():]
def shift(mt):
    off = int(mt.group(1), 16)
    return f'@0x{off + delta:08x}' if off >= kernel_end else mt.group(0)
content = re.sub(r'@0x([0-9a-fA-F]+)', shift, content)
open(param_file, 'w').write(content)
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
[ -n "$UINITRD" ] && { cp "$UINITRD" "$TARGET_DIR/uInitrd"; log "  ✓ uInitrd"; }

# ============================================================
# 6.9 重建 boot.img
# ============================================================
log "[6.9/9] 重建 boot.img"
BOOT_IMG="$TARGET_DIR/boot.img"
UINITRD_FILE="$TARGET_DIR/uInitrd"

if [ -f "$UINITRD_FILE" ]; then
  [ -f "$BOOT_IMG" ] && cp "$BOOT_IMG" "$WORK_DIR/boot.img.orig" 2>/dev/null || true

  UINITRD_MAGIC=$(dd if="$UINITRD_FILE" bs=1 count=4 2>/dev/null | xxd -p)
  log "  uInitrd magic: $UINITRD_MAGIC"

  RAW_PAYLOAD=""
  case "$UINITRD_MAGIC" in
    27051956*)
      mkdir -p "$WORK_DIR/boot_extract"
      RAW_PAYLOAD="$WORK_DIR/boot_extract/raw_payload"
      tail -c +65 "$UINITRD_FILE" > "$RAW_PAYLOAD"
      log "  剥离 64 字节头: $(stat -c%s "$RAW_PAYLOAD") bytes"
      ;;
    1f8b08*) RAW_PAYLOAD="$UINITRD_FILE" ;;
    *) warn "  未知格式 ($UINITRD_MAGIC)" ;;
  esac

  RAMDISK=""
  if [ -n "$RAW_PAYLOAD" ] && [ -s "$RAW_PAYLOAD" ]; then
    PM=$(dd if="$RAW_PAYLOAD" bs=1 count=4 2>/dev/null | xxd -p)
    log "  payload magic: $PM"
    case "$PM" in
      1f8b08*) RAMDISK="$RAW_PAYLOAD" ;;
      fd377a58*)
        mkdir -p "$WORK_DIR/boot_extract"
        unxz -c "$RAW_PAYLOAD" > "$WORK_DIR/boot_extract/raw" 2>/dev/null || true
        [ -s "$WORK_DIR/boot_extract/raw" ] && {
          gzip -9 -c "$WORK_DIR/boot_extract/raw" > "$WORK_DIR/boot_extract/raw.gz"
          RAMDISK="$WORK_DIR/boot_extract/raw.gz"
          log "  XZ→gzip: $(stat -c%s "$RAMDISK") bytes"
        }
        ;;
      04224d18*)
        mkdir -p "$WORK_DIR/boot_extract"
        lz4 -d -c "$RAW_PAYLOAD" > "$WORK_DIR/boot_extract/raw" 2>/dev/null || true
        [ -s "$WORK_DIR/boot_extract/raw" ] && {
          gzip -9 -c "$WORK_DIR/boot_extract/raw" > "$WORK_DIR/boot_extract/raw.gz"
          RAMDISK="$WORK_DIR/boot_extract/raw.gz"
        }
        ;;
      *) RAMDISK="$RAW_PAYLOAD" ;;
    esac
  fi

  if [ -n "$RAMDISK" ] && [ -s "$RAMDISK" ]; then
    python3 - "$RAMDISK" "$BOOT_IMG" <<'BOOT_BUILD'
import sys, struct
data = open(sys.argv[1], 'rb').read()
hdr = b'KRNL' + struct.pack('<I', len(data))
with open(sys.argv[2], 'wb') as f:
    f.write(hdr); f.write(data); f.write(b'\x00\x00\x00\x00')
print(f"    data={len(data)}  total={len(hdr)+len(data)+4}")
BOOT_BUILD
    NEW_MAGIC=$(dd if="$BOOT_IMG" bs=1 count=4 2>/dev/null)
    NEW_PAYLOAD=$(dd if="$BOOT_IMG" bs=1 skip=8 count=4 2>/dev/null | xxd -p)
    log "  boot.img: magic=$NEW_MAGIC, payload=$NEW_PAYLOAD, size=$(stat -c%s "$BOOT_IMG")"
  fi
fi

# ============================================================
# ★★★ 6.7 resource.img 深度诊断（v47 新增）★★★
# ============================================================
log ""
log "════════════════════════════════════════════════════════"
log "  ★ [6.7/9] resource.img 深度诊断"
log "════════════════════════════════════════════════════════"

RESOURCE_IMG="$TARGET_DIR/resource.img"
if [ -f "$RESOURCE_IMG" ]; then
  RES_SIZE=$(stat -c%s "$RESOURCE_IMG")
  log "  resource.img 总大小: $RES_SIZE bytes"
  log ""
  log "  ── 前 4KB hex ──"
  xxd -l 4096 "$RESOURCE_IMG" | sed 's/^/    /'
  log ""
  log "  ── 搜索 'rk-kernel.dtb' 字符串位置 ──"
  grep -abo "rk-kernel.dtb" "$RESOURCE_IMG" 2>/dev/null | head -10 | sed 's/^/    /' || echo "    (未找到)"
  log ""
  log "  ── 搜索所有 FDT magic (d00dfeed) 位置 ──"
  python3 -c "
raw = open('$RESOURCE_IMG','rb').read()
magic = b'\xd0\x0d\xfe\xed'
idxs = []
i = 0
while True:
    j = raw.find(magic, i)
    if j < 0: break
    idxs.append(j)
    i = j + 1
    if len(idxs) > 20: break
print(f'    共 {len(idxs)} 个 FDT:')
for off in idxs:
    print(f'      @ 0x{off:x} ({off})')
"
  log ""
  log "  ── 搜索所有 'RSCE' 位置 ──"
  grep -abo "RSCE" "$RESOURCE_IMG" 2>/dev/null | head -10 | sed 's/^/    /' || echo "    (未找到)"
  log ""
  log "  ── 搜索已知 resource 子文件名字符串 ──"
  for name in "logo.bmp" "logo_kernel.bmp" "resource" "rk-kernel" "dtb"; do
    POS=$(grep -abo "$name" "$RESOURCE_IMG" 2>/dev/null | head -3 | awk -F: '{print $1}' | tr '\n' ' ')
    if [ -n "$POS" ]; then
      log "    '$name': $POS"
    fi
  done
  log ""

  # 尝试解析 RSCE 头
  log "  ── 尝试解析 RSCE 头 ──"
  python3 -c "
import struct
raw = open('$RESOURCE_IMG','rb').read()

# 前 32 字节
print('    前 32 字节逐字段解读:')
print(f'      [0x00:0x04] = {raw[0:4]!r}')
print(f'      [0x04:0x08] = 0x{struct.unpack_from(\"<I\", raw, 4)[0]:08x}')
print(f'      [0x08:0x0c] = 0x{struct.unpack_from(\"<I\", raw, 8)[0]:08x}')
print(f'      [0x0c:0x10] = 0x{struct.unpack_from(\"<I\", raw, 12)[0]:08x}')
print(f'      [0x10:0x14] = 0x{struct.unpack_from(\"<I\", raw, 16)[0]:08x}')
print(f'      [0x14:0x18] = 0x{struct.unpack_from(\"<I\", raw, 20)[0]:08x}')
print(f'      [0x18:0x1c] = 0x{struct.unpack_from(\"<I\", raw, 24)[0]:08x}')
print(f'      [0x1c:0x20] = 0x{struct.unpack_from(\"<I\", raw, 28)[0]:08x}')

# 尝试在偏移 8 处找文件名（找 'rk-kernel.dtb' 字符串）
for name_to_find in [b'rk-kernel.dtb', b'logo.bmp', b'logo_kernel.bmp']:
    idx = raw.find(name_to_find)
    if idx > 0:
        print(f'    找到 {name_to_find!r} @ 0x{idx:x}')
        # 往前找可能的 name 字段起点（假设 name 字段 256 字节）
        for test_entry_start in [idx - 256, idx]:
            if test_entry_start >= 0:
                # 尝试读 entry 结构
                if test_entry_start + 264 <= len(raw):
                    off_v = struct.unpack_from('<I', raw, test_entry_start + 256)[0]
                    size_v = struct.unpack_from('<I', raw, test_entry_start + 260)[0]
                    print(f'      [假设 entry 起 0x{test_entry_start:x}]: offset=0x{off_v:x} size=0x{size_v:x}')
"
  log ""
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

grep -E "RAW\.[0-9]|successfully|Invalid|Error" /tmp/mk-sd.log | sed 's/^/    /'

if ! grep -q "RAW image successfully created" /tmp/mk-sd.log; then
  err "  mk-sd-image.sh 未成功"; exit 1
fi

FOUND_IMG=$(find out -maxdepth 1 -name "*.img" -print -quit)
[ -z "$FOUND_IMG" ] && { err "  无 img"; exit 1; }
mv "$FOUND_IMG" "$OUTPUT_IMG"
log "  镜像: $OUTPUT_IMG ($(stat -c%s "$OUTPUT_IMG") bytes)"

# ============================================================
# 8. 全面静态验证
# ============================================================
log ""
log "════════════════════════════════════════════════════════"
log "  ★ [8/9] 全面静态验证"
log "════════════════════════════════════════════════════════"

PASS=0; FAIL=0
ok()  { log "  ✅ $*"; PASS=$((PASS+1)); }
bad() { err "  ❌ $*"; FAIL=$((FAIL+1)); }
info() { log "  ℹ️  $*"; }

IMG="$OUTPUT_IMG"
IMG_SIZE=$(stat -c%s "$IMG")

# 8.1
log ""
log "── 8.1 parameter.txt 分区表 ──"
CMDLINE=$(grep -E '^CMDLINE:' "$PARAM_FILE" | head -1)
PARTS=$(echo "$CMDLINE" | sed -E 's/.*mtdparts=[^:]+://')

declare -A PART_SIZE PART_OFF
TOTAL_END=0
while IFS= read -r part; do
  SIZE_HEX=$(echo "$part" | sed -E 's/^(-?|0x[0-9a-fA-F]+)@(0x[0-9a-fA-F]+)\(([^)]+)\).*/\1/')
  OFF_HEX=$(echo "$part" | sed -E 's/^(-?|0x[0-9a-fA-F]+)@(0x[0-9a-fA-F]+)\(([^)]+)\).*/\2/')
  NAME=$(echo "$part" | sed -E 's/^(-?|0x[0-9a-fA-F]+)@(0x[0-9a-fA-F]+)\(([^)]+)\).*/\3/')
  NAME="${NAME%%:*}"
  if [ -z "$NAME" ] || [ "$SIZE_HEX" = "-" ] || [ -z "$SIZE_HEX" ]; then continue; fi
  SIZE=$(( SIZE_HEX )); OFF=$(( OFF_HEX ))
  PART_SIZE[$NAME]=$SIZE; PART_OFF[$NAME]=$OFF
  END=$(( OFF + SIZE ))
  [ $END -gt $TOTAL_END ] && TOTAL_END=$END
  log "    $NAME: off=0x$(printf %x $OFF) size=$(( SIZE * 512 / 1024 / 1024 ))MiB"
done < <(echo "$PARTS" | tr ',' '\n')

IMG_SECTORS=$(( IMG_SIZE / 512 ))
if [ $TOTAL_END -gt $IMG_SECTORS ]; then
  bad "分区总结束 > img 容量"
else
  ok "分区总和 ≤ img 容量（余量 $(( (IMG_SECTORS - TOTAL_END) * 512 / 1024 / 1024 ))MiB）"
fi

OPTIONAL_PARTS=" recovery opt userdata "
for part in "${!PART_SIZE[@]}"; do
  FILE="$TARGET_DIR/${part}.img"
  if [ ! -f "$FILE" ]; then
    if echo "$OPTIONAL_PARTS" | grep -q " $part "; then
      info "$part: 可选分区，无 ${part}.img"
    else
      bad "$part: 缺 ${part}.img"
    fi
    continue
  fi
  FSIZE=$(stat -c%s "$FILE")
  PSIZE=$(( ${PART_SIZE[$part]:-0} * 512 ))
  if [ $PSIZE -eq 0 ]; then info "$part: (grow)"
  elif [ $FSIZE -gt $PSIZE ]; then bad "$part: 文件 > 分区"
  fi
done

# 8.2
log ""
log "── 8.2 最终 img 内各分区首部 magic ──"
check_magic() {
  local name="$1" expected_hex="$2" desc="$3"
  local off=$(( ${PART_OFF[$name]:-0} * 512 ))
  [ $off -eq 0 ] && return
  local actual=$(dd if="$IMG" bs=1 skip=$off count=4 2>/dev/null | xxd -p)
  if [ "$actual" = "$expected_hex" ]; then ok "$name @ $off: $desc ($actual)"
  else bad "$name @ $off: magic=$actual (期望 $expected_hex)"
  fi
}
check_magic uboot      "d00dfeed"  "RK U-Boot (FDT)"
check_magic resource   "52534345"  "RSCE"
check_magic kernel     "4b524e4c"  "KRNL"
check_magic boot       "4b524e4c"  "KRNL"

BOOT_OFF=$(( ${PART_OFF[boot]:-0} * 512 ))
if [ $BOOT_OFF -gt 0 ]; then
  BOOT_PAYLOAD=$(dd if="$IMG" bs=1 skip=$(( BOOT_OFF + 8 )) count=4 2>/dev/null | xxd -p)
  if [ "$BOOT_PAYLOAD" = "1f8b0800" ] || [ "$BOOT_PAYLOAD" = "1f8b0808" ]; then
    ok "boot 分区 payload=gzip"
  else
    bad "boot 分区 payload=$BOOT_PAYLOAD"
  fi
fi

ROOTFS_OFF=$(( ${PART_OFF[rootfs]:-0} * 512 ))
if [ $ROOTFS_OFF -gt 0 ]; then
  RM2=$(dd if="$IMG" bs=1 skip=$(( ROOTFS_OFF + 0x438 )) count=2 2>/dev/null | xxd -p)
  [ "$RM2" = "53ef" ] && ok "rootfs ext4 magic=53ef" || bad "rootfs magic=$RM2"
fi

# 8.3
log ""
log "── 8.3 与官方固件对比 ──"
OFFICIAL_IMG=$(find "$OFFICIAL_DIR" -maxdepth 1 -name "*.img" 2>/dev/null | head -1 || true)
if [ -n "$OFFICIAL_IMG" ] && [ -f "$OFFICIAL_IMG" ]; then
  OFF_FMT=$(file -b "$OFFICIAL_IMG")
  info "官方格式: $OFF_FMT"
fi

# 8.4 rootfs 挂载
log ""
log "── 8.4 rootfs 挂载校验 ──"
ROOTFS_CHECK="$WORK_DIR/rootfs_check"
mkdir -p "$ROOTFS_CHECK"
if [ $ROOTFS_OFF -gt 0 ]; then
  ROOTFS_EXTRACT="$WORK_DIR/rootfs_extract.img"
  dd if="$IMG" bs=1M skip=$(( ROOTFS_OFF / 1024 / 1024 )) \
     of="$ROOTFS_EXTRACT" count=$(( ${PART_SIZE[rootfs]:-0} * 512 / 1024 / 1024 )) 2>/dev/null
  if sudo mount -o loop,ro "$ROOTFS_EXTRACT" "$ROOTFS_CHECK" 2>/dev/null; then
    ok "rootfs 可挂载"
    sudo test -d "$ROOTFS_CHECK/lib/modules/$KVER" && ok "含 $KVER 模块目录" || bad "缺模块目录"
    KOS=$(sudo find "$ROOTFS_CHECK/lib/modules/$KVER" -name '*.ko*' 2>/dev/null | wc -l)
    [ "$KOS" -ge 1000 ] && ok "含 $KOS 个 ko" || bad "仅 $KOS 个 ko"
    sudo test -x "$ROOTFS_CHECK/sbin/init" && ok "含 /sbin/init" || bad "缺 /sbin/init"
    sudo umount "$ROOTFS_CHECK"
  else
    bad "rootfs 无法挂载"
  fi
fi

# 8.5 boot payload
log ""
log "── 8.5 boot payload 完整性 ──"
if [ -f "$BOOT_IMG" ]; then
  BOOT_SIZE=$(stat -c%s "$BOOT_IMG")
  dd if="$BOOT_IMG" bs=1 skip=8 count=$(( BOOT_SIZE - 12 )) of="$WORK_DIR/boot_payload.gz" 2>/dev/null
  if gunzip -t "$WORK_DIR/boot_payload.gz" 2>/dev/null; then
    ok "boot payload gzip 完整性通过"
    DSIZE=$(gunzip -c "$WORK_DIR/boot_payload.gz" 2>/dev/null | wc -c)
    [ "$DSIZE" -gt 1000000 ] && ok "解压 $DSIZE bytes" || bad "解压仅 $DSIZE bytes"
  else
    bad "boot payload gzip 损坏"
  fi
fi

log ""
log "════════════════════════════════════════════════════════"
log "  验证结果: 通过 $PASS 项 / 失败 $FAIL 项"
log "════════════════════════════════════════════════════════"

[ "$FAIL" -gt 0 ] && exit 1

log "  ✅ 所有静态验证通过"

# ============================================================
# 9. 汇总
# ============================================================
log ""
log "[9/9] 汇总"
log "  内核: $SELECTED_VER ($SELECTED_REPO/$SELECTED_RELEASE)"
log "  kernel.img: $(stat -c%s "$TARGET_DIR/kernel.img")"
log "  boot.img:   $(stat -c%s "$TARGET_DIR/boot.img")"
log "  rootfs.img: $(stat -c%s "$TARGET_DIR/rootfs.img")"
log "  img:        $OUTPUT_IMG ($IMG_SIZE)"
log ""
log "完成 (version $VERSION)"