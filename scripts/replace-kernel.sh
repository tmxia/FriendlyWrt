#!/bin/bash
# replace-kernel.sh - Flippy 内核 + 模块注入 + DTB 探测 → 官方 KRNL 结构
set -euo pipefail

VERSION="2026-09-11-v36-bootimg-diagnose"
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
off_path = sys.argv[3] if len(sys.argv) > 3 else None
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
[ -n "$UINITRD" ] && { cp "$UINITRD" "$TARGET_DIR/uInitrd"; log "  ✓ uInitrd"; }

# ============================================================
# 6.5 更新 resource.img DTB（保守方案）
# ============================================================
log "[6.5/9] 尝试更新 resource.img DTB"
RESOURCE_IMG="$TARGET_DIR/resource.img"
if [ -f "$RESOURCE_IMG" ]; then
  log "  resource.img: $(stat -c%s "$RESOURCE_IMG") bytes"
  log "  前 64 字节:"
  xxd -l 64 "$RESOURCE_IMG" | sed 's/^/    /'
  # RSCE 真实结构仍未确认，保守起见不动
  warn "  RSCE 格式未确认，跳过修改（v36 仅探测）"
fi

# ============================================================
# ★★★ 6.7 探测 boot.img 内部结构 ★★★
# ============================================================
log ""
log "════════════════════════════════════════════════════════"
log "  ★ [6.7/9] 关键诊断: boot.img 内部结构"
log "════════════════════════════════════════════════════════"

BOOT_IMG="$TARGET_DIR/boot.img"
if [ -f "$BOOT_IMG" ]; then
  BOOT_SIZE=$(stat -c%s "$BOOT_IMG")
  log "  boot.img 大小: $BOOT_SIZE bytes"
  log ""
  log "  ── 前 256 字节 hex ──"
  xxd -l 256 "$BOOT_IMG" | sed 's/^/    /'
  log ""
  log "  ── 前 32 字节 ASCII ──"
  head -c 32 "$BOOT_IMG" | xxd | sed 's/^/    /'
  log ""

  # 检测 magic
  MAGIC4=$(dd if="$BOOT_IMG" bs=1 count=4 2>/dev/null | xxd -p)
  MAGIC8=$(dd if="$BOOT_IMG" bs=1 count=8 2>/dev/null | xxd -p)
  log "  magic (前 4 字节 hex): $MAGIC4"
  log "  magic (前 8 字节 hex): $MAGIC8"

  # file 类型
  BOOT_FILE=$(file -b "$BOOT_IMG")
  log "  file 输出: $BOOT_FILE"
  log ""

  # 按 magic 判断格式
  case "$MAGIC8" in
    414e44524f494421*)
      log "  ★ 检测到 Android boot image (ANDROID! magic)"
      ;;
    d00dfeed*)
      log "  ★ 检测到 FIT image (d00dfeed magic)"
      ;;
    27051956*)
      log "  ★ 检测到 U-Boot legacy image (27051956 magic)"
      ;;
    *)
      log "  ⚠ 未知 magic，可能是 RK 特有格式"
      ;;
  esac
  log ""

  # 尝试 mkimage -l（U-Boot legacy image）
  if command -v mkimage >/dev/null 2>&1; then
    log "  ── mkimage -l 输出 ──"
    mkimage -l "$BOOT_IMG" 2>&1 | head -30 | sed 's/^/    /'
    log ""
  fi

  # 尝试 dumpimage -l（更详细）
  if command -v dumpimage >/dev/null 2>&1; then
    log "  ── dumpimage -l 输出 ──"
    dumpimage -l "$BOOT_IMG" 2>&1 | head -40 | sed 's/^/    /'
    log ""
  fi

  # 搜索内部特殊 magic
  log "  ── 内部 magic 搜索 ──"
  python3 -c "
raw = open('$BOOT_IMG','rb').read()
magics = {
    'FDT (d00dfeed)': b'\xd0\x0d\xfe\xed',
    'Gzip (1f8b08)': b'\x1f\x8b\x08',
    'LZ4 (04224d18)': b'\x04\x22\x4d\x18',
    'LZMA (5d0000)': b'\x5d\x00\x00',
    'XZ (fd377a58)': b'\xfd\x37\x7a\x58',
    'Zstd (28b52ffd)': b'\x28\xb5\x2f\xfd',
    'Squashfs (hsqs)': b'hsqs',
    'Ext4 (53ef)': b'\x53\xef',
    'Android dtb (ANDROID!)': b'ANDROID!',
    'RKDTB (RKDT)': b'RKDT',
}
for name, m in magics.items():
    idx = raw.find(m)
    if idx >= 0:
        print(f'    {name} @ 0x{idx:x}')
"
  log ""

  # 如果识别出是 legacy image，尝试解包
  if [ "$(dd if="$BOOT_IMG" bs=1 count=4 2>/dev/null | xxd -p)" = "27051956" ]; then
    log "  ── 尝试 dumpimage 解包 ──"
    mkdir -p "$WORK_DIR/boot_extracted"
    dumpimage -i "$BOOT_IMG" -o "$WORK_DIR/boot_extracted/kernel" -T kernel "$BOOT_IMG" 2>&1 | head -5 | sed 's/^/    /' || true
    if [ -f "$WORK_DIR/boot_extracted/kernel" ]; then
      KSIZE=$(stat -c%s "$WORK_DIR/boot_extracted/kernel")
      log "    kernel 提取: $KSIZE bytes"
      log "    前 32 字节:"
      xxd -l 32 "$WORK_DIR/boot_extracted/kernel" | sed 's/^/      /'
    fi
  fi

  # 如果是 FIT image，尝试提取
  FDT_OFF=$(python3 -c "
raw = open('$BOOT_IMG','rb').read()
print(raw.find(b'\xd0\x0d\xfe\xed'))
")
  if [ "$FDT_OFF" != "-1" ] && [ "$FDT_OFF" -lt 1000 ]; then
    log "  ── 是 FIT image，尝试提取 device tree 结构 ──"
    dd if="$BOOT_IMG" bs=1 skip=0 count=$(( BOOT_SIZE > 65536 ? 65536 : BOOT_SIZE )) of="$WORK_DIR/boot_fdt.dtb" 2>/dev/null || true
    if command -v dtc >/dev/null 2>&1; then
      dtc -I dtb -O dts "$WORK_DIR/boot_fdt.dtb" 2>/dev/null | head -100 | sed 's/^/    /' || true
    fi
  fi
else
  warn "  boot.img 不存在！"
fi

log ""
log "════════════════════════════════════════════════════════"
log "  [6.7/9] 诊断结束"
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

# ============================================================
# 9. 汇总
# ============================================================
log "[9/9] 汇总"
log "  resource.img: $(stat -c%s "$TARGET_DIR/resource.img" 2>/dev/null || echo 'N/A')"
log "  kernel.img:   $(stat -c%s "$TARGET_DIR/kernel.img")"
log "  boot.img:     $(stat -c%s "$TARGET_DIR/boot.img" 2>/dev/null || echo 'N/A')"
log "  rootfs.img:   $(stat -c%s "$TARGET_DIR/rootfs.img")"

log ""
log "★ 请把 [6.7/9] 段的完整输出贴给我 ★"
log ""
log "完成 (version $VERSION, 内核 $SELECTED_VER)"