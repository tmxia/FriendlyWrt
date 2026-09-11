#!/bin/bash
# replace-kernel.sh - Flippy 内核转换 + 分区扩容
# 用法: replace-kernel.sh <images.tgz> <sd-fuse目录> <dist_name> <输出img路径>
set -euo pipefail

VERSION="2026-09-11-v19-official-aligned"
log()  { echo -e "\033[0;32m[replace]\033[0m $*"; }
warn() { echo -e "\033[0;33m[replace]\033[0m $*"; }
err()  { echo -e "\033[0;31m[replace]\033[0m $*" >&2; }
log "replace-kernel.sh version: $VERSION"

IMAGES_TGZ="$1"; SDFUSE_DIR="$2"; DIST_NAME="$3"; OUTPUT_IMG="$4"
TARGET_MODEL="${TARGET_MODEL:-r5s}"
KERNEL_VERSION="${KERNEL_VERSION:-6.18.y}"

WORK_DIR=$(mktemp -d /tmp/replace-kernel.XXXXXX)
trap "rm -rf $WORK_DIR" EXIT

# ============================================================
# 1. 解压 images.tgz
# ============================================================
log "========== [1/8] 解压 images.tgz =========="
mkdir -p "$WORK_DIR/base"
tar xzf "$IMAGES_TGZ" -C "$WORK_DIR/base"
BASE_DIR=$(find "$WORK_DIR/base" -maxdepth 2 -type d -name "friendlywrt*" | head -1)
[ -z "$BASE_DIR" ] && { err "找不到顶层目录"; exit 1; }

# ============================================================
# 2. 扫描内核
# ============================================================
log "========== [2/8] 扫描 $KERNEL_VERSION =========="

declare -A VER_TO_SOURCE
SCAN_LIST=(
  "ophub/kernel:kernel_flippy"
  "ophub/kernel:kernel_rk35xx"
  "breakingbadboy/OpenWrt:kernel_rk35xx"
  "breakingbadboy/OpenWrt:kernel_stable"
)

case "$KERNEL_VERSION" in
  6.18*|6.18.y) PREFIX="6.18" ;;
  6.12*|6.12.y) PREFIX="6.12" ;;
  6.6*|6.6.y)   PREFIX="6.6" ;;
  6.1*|6.1.y)   PREFIX="6.1" ;;
  auto|"")      PREFIX="" ;;
  *)            PREFIX="$KERNEL_VERSION" ;;
esac

for target in "${SCAN_LIST[@]}"; do
  REPO="${target%%:*}"; RELEASE="${target##*:}"
  log "  扫描 $REPO / $RELEASE ..."
  ASSETS=$(gh release view "$RELEASE" --repo "$REPO" --json assets --jq '.assets[].name' 2>/dev/null || echo "")
  [ -z "$ASSETS" ] && { log "    (无资产)"; continue; }

  if [ -n "$PREFIX" ]; then
    VERS=$(echo "$ASSETS" | grep -E "^${PREFIX}\.[0-9]+\.tar\.gz$" | sed 's/\.tar\.gz//' | sort -V || echo "")
  else
    VERS=$(echo "$ASSETS" | grep -E '^6\.[0-9]+\.[0-9]+\.tar\.gz$' | sed 's/\.tar\.gz//' | sort -V || echo "")
  fi
  [ -z "$VERS" ] && continue

  echo "$VERS" | sed 's/^/      /'
  for v in $VERS; do
    [ -z "${VER_TO_SOURCE[$v]:-}" ] && VER_TO_SOURCE["$v"]="$REPO:$RELEASE"
  done
done

[ ${#VER_TO_SOURCE[@]} -eq 0 ] && { err "  无匹配内核"; exit 1; }

SELECTED_VER=$(printf '%s\n' "${!VER_TO_SOURCE[@]}" | sort -V | tail -1)
SELECTED_SOURCE="${VER_TO_SOURCE[$SELECTED_VER]}"
SELECTED_REPO="${SELECTED_SOURCE%%:*}"
SELECTED_RELEASE="${SELECTED_SOURCE##*:}"
log "  选中: $SELECTED_VER (来自 $SELECTED_REPO / $SELECTED_RELEASE)"

# ============================================================
# 3. 下载
# ============================================================
log "========== [3/8] 下载 =========="

KERNEL_CACHE="/tmp/kernel-cache-${SELECTED_RELEASE}/${SELECTED_VER}"
if [ ! -f "$KERNEL_CACHE/.ready" ]; then
  rm -rf "$KERNEL_CACHE"; mkdir -p "$KERNEL_CACHE"; cd "$KERNEL_CACHE"
  URL="https://github.com/${SELECTED_REPO}/releases/download/${SELECTED_RELEASE}/${SELECTED_VER}.tar.gz"
  log "  URL: $URL"
  wget -q --timeout=120 --tries=2 "$URL" -O kernel.tar.gz 2>/dev/null \
    || curl -L -f --max-time 300 "$URL" -o kernel.tar.gz

  tar xzf kernel.tar.gz
  LOCAL_KDIR="$SELECTED_VER"
  [ ! -d "$LOCAL_KDIR" ] && LOCAL_KDIR=$(find . -maxdepth 2 -type d -name "*${SELECTED_VER}*" ! -path "./boot*" ! -path "./dtb*" ! -path "./modules*" | head -1)
  echo "$KERNEL_CACHE/$LOCAL_KDIR" > "$KERNEL_CACHE/.topdir"

  for type in boot dtb modules; do
    TAR=$(find "$LOCAL_KDIR" -maxdepth 1 -name "${type}-*.tar.gz" | head -1)
    [ -z "$TAR" ] && [ "$type" = "dtb" ] && TAR=$(find "$LOCAL_KDIR" -maxdepth 1 -name "dtb-rockchip-*.tar.gz" | head -1)
    [ -n "$TAR" ] && tar xzf "$TAR" -C "$KERNEL_CACHE" && log "  ✓ 解压 $type"
  done
  touch .ready
fi
KERNEL_TOPDIR=$(cat "$KERNEL_CACHE/.topdir" 2>/dev/null || echo "$KERNEL_CACHE/$SELECTED_VER")

# ============================================================
# 4. 复制骨架
# ============================================================
log "========== [4/8] 复制骨架 =========="
TARGET_DIR="$SDFUSE_DIR/$DIST_NAME"
rm -rf "$TARGET_DIR"
cp -a "$BASE_DIR" "$TARGET_DIR"

# ============================================================
# 5. PE → KRNL 转换
# ============================================================
log "========== [5/8] 构造 kernel.img =========="

IMAGE_FILE=$(find "$KERNEL_CACHE" -maxdepth 3 -type f -name "vmlinuz-*" | head -1)
[ -z "$IMAGE_FILE" ] && IMAGE_FILE=$(find "$KERNEL_CACHE" -maxdepth 3 -type f -name "Image*" | head -1)
[ -z "$IMAGE_FILE" ] && { err "找不到内核 Image"; exit 1; }

log "  文件: $(basename "$IMAGE_FILE") ($(stat -c%s "$IMAGE_FILE") bytes)"
xxd -l 64 "$IMAGE_FILE" | sed 's/^/    /'

python3 - "$IMAGE_FILE" "$TARGET_DIR/kernel.img" <<'PYEOF'
import sys, struct

src, dst = sys.argv[1], sys.argv[2]
raw = open(src, 'rb').read()
ARM64_MAGIC = b'ARM\x64'

print("  输入大小: %d" % len(raw))

if raw[:4] == b'KRNL':
    open(dst, 'wb').write(raw); print("  已是 KRNL"); sys.exit(0)

if raw[:2] != b'MZ':
    idx = raw.find(ARM64_MAGIC)
    if idx == 0x38 and raw[0:4] == b'\x1f\x20\x03\xd5':
        open(dst, 'wb').write(b'KRNL' + struct.pack('<I', len(raw)) + raw)
        print("  裸机 Image 直接封装"); sys.exit(0)
    print("  未知格式"); sys.exit(1)

pe_off = struct.unpack_from('<I', raw, 0x3C)[0]
assert raw[pe_off:pe_off+4] == b'PE\x00\x00'
coff = pe_off + 4
nsec = struct.unpack_from('<H', raw, coff + 2)[0]
opt_size = struct.unpack_from('<H', raw, coff + 16)[0]
opt_off = coff + 20
sec_base = opt_off + opt_size
entry_rva = struct.unpack_from('<I', raw, opt_off + 0x10)[0]

print("  EntryRVA=0x%x  Sections=%d" % (entry_rva, nsec))

sections = []
for i in range(nsec):
    o = sec_base + i * 40
    name = raw[o:o+8].rstrip(b'\x00').decode('ascii', 'ignore')
    vsize = struct.unpack_from('<I', raw, o + 8)[0]
    vaddr = struct.unpack_from('<I', raw, o + 12)[0]
    rsize = struct.unpack_from('<I', raw, o + 16)[0]
    roff  = struct.unpack_from('<I', raw, o + 20)[0]
    sections.append((name, vaddr, vsize, roff, rsize))
    print("    %-8s RVA=0x%08x Off=0x%08x Size=0x%08x" % (name, vaddr, roff, rsize))

text = None; text_vaddr = None; text_fileoff = None
for name, vaddr, vsize, roff, rsize in sections:
    if name == '.text':
        text = raw[roff:roff+rsize]; text_vaddr = vaddr; text_fileoff = roff
        break
assert text is not None, "找不到 .text"

has_header = (len(text) >= 0x40 and text[0x38:0x3c] == ARM64_MAGIC
              and text[0:4] == b'\x1f\x20\x03\xd5')

if has_header:
    code1_t = struct.unpack_from('<I', text, 0x04)[0]
    if (code1_t & 0xFC000000) == 0x14000000:
        print("  >>> 方案 1: .text 内含完整 Image header, 直接透传")
        print("      code1=0x%08x (与官方对齐)" % code1_t)
        knl_payload = text
    else:
        has_header = False

if not has_header:
    print("  >>> 方案 2: 按 EntryPoint 构造 header")
    entry_fileoff = None
    for name, vaddr, vsize, roff, rsize in sections:
        if vaddr <= entry_rva < vaddr + vsize:
            entry_fileoff = roff + (entry_rva - vaddr)
            break
    if entry_fileoff is None:
        entry_fileoff = text_fileoff
    entry_in_text = entry_fileoff - text_fileoff

    header_len = 0x40
    entry_in_krnl = 0x08 + header_len + entry_in_text
    rel = entry_in_krnl - 0x0c
    assert rel % 4 == 0
    code1 = 0x14000000 | ((rel // 4) & 0x03FFFFFF)
    print("      entry_in_text=0x%x  code1=0x%08x" % (entry_in_text, code1))

    hdr = bytearray(header_len)
    struct.pack_into('<I', hdr, 0x00, 0xd503201f)
    struct.pack_into('<I', hdr, 0x04, code1)
    struct.pack_into('<Q', hdr, 0x08, 0)
    struct.pack_into('<Q', hdr, 0x10, len(text))
    struct.pack_into('<Q', hdr, 0x18, 0x0a)
    hdr[0x38:0x3c] = ARM64_MAGIC
    knl_payload = bytes(hdr) + text

knl = b'KRNL' + struct.pack('<I', len(knl_payload)) + knl_payload
open(dst, 'wb').write(knl)

out = open(dst, 'rb').read(0x80)
assert out[0:4] == b'KRNL'
assert out[0x08:0x0c] == b'\x1f\x20\x03\xd5'
assert out[0x40:0x44] == ARM64_MAGIC

print("  ✓ 完成")
print("    code0=0x%s  code1=0x%s  magic@0x40"
      % (out[0x08:0x0c].hex(), out[0x0c:0x10].hex()))
PYEOF

log "  新 kernel.img: $(stat -c%s "$TARGET_DIR/kernel.img") bytes"

# ============================================================
# 5.5 扩容 kernel 分区
# ============================================================
log "========== [5.5/8] 扩容 kernel 分区 =========="

PARAM_FILE="$TARGET_DIR/parameter.txt"
python3 - "$PARAM_FILE" "$(stat -c%s "$TARGET_DIR/kernel.img")" <<'PARAM_PYEOF'
import re, sys
param_file, kernel_size = sys.argv[1], int(sys.argv[2])
with open(param_file) as f:
    content = f.read()

m = re.search(r'0x([0-9a-fA-F]+)@(0x[0-9a-fA-F]+)\(kernel\)', content, re.IGNORECASE)
if not m:
    print("[param] 未找到 kernel"); sys.exit(0)

old_size = int(m.group(1), 16)
kernel_off = int(m.group(2), 16)
kernel_end = kernel_off + old_size

need = (kernel_size + 511) // 512
rounded = ((need + 0x3FFF) // 0x4000) * 0x4000
new_size = max(rounded, old_size)

print(f"[param] old={old_size*512/1024/1024:.1f} MiB need={need*512/1024/1024:.1f} MiB new={new_size*512/1024/1024:.1f} MiB")

if new_size == old_size:
    print("[param] 无需扩容"); sys.exit(0)

delta = new_size - old_size
content = content[:m.start()] + f'0x{new_size:08x}@{m.group(2)}(kernel)' + content[m.end():]

def shift(mt):
    off = int(mt.group(1), 16)
    return f'@0x{off + delta:08x}' if off >= kernel_end else mt.group(0)
content = re.sub(r'@0x([0-9a-fA-F]+)', shift, content)

with open(param_file, 'w') as f:
    f.write(content)
print(f"[param] 已更新 delta={delta} sectors")
PARAM_PYEOF

sed 's/^/    /' "$PARAM_FILE"

# ============================================================
# 6. dtb + uInitrd
# ============================================================
log "========== [6/8] dtb + uInitrd =========="

DTB_TAR=$(find "$KERNEL_CACHE" -maxdepth 2 -name "dtb-rockchip-*.tar.gz" | head -1)
if [ -n "$DTB_TAR" ]; then
  mkdir -p "$TARGET_DIR/dtb/rockchip"
  R5S=$(tar tzf "$DTB_TAR" | grep -E "(^|/)rk3568-nanopi-r5s\.dtb$" | head -1 || echo "")
  R5C=$(tar tzf "$DTB_TAR" | grep -E "(^|/)rk3568-nanopi-r5c\.dtb$" | head -1 || echo "")
  [ -n "$R5S" ] && { tar xzf "$DTB_TAR" -C "$WORK_DIR" "$R5S"; cp "$WORK_DIR/$R5S" "$TARGET_DIR/dtb/rockchip/rk3568-nanopi-r5s.dtb"; log "  ✓ r5s dtb"; }
  [ -n "$R5C" ] && { tar xzf "$DTB_TAR" -C "$WORK_DIR" "$R5C"; cp "$WORK_DIR/$R5C" "$TARGET_DIR/dtb/rockchip/rk3568-nanopi-r5c.dtb"; log "  ✓ r5c dtb"; }
fi

UINITRD=$(find "$KERNEL_CACHE" -type f -name "uInitrd-*" | head -1)
[ -n "$UINITRD" ] && { cp "$UINITRD" "$TARGET_DIR/uInitrd"; log "  ✓ uInitrd"; }

# ============================================================
# 7. 生成镜像
# ============================================================
log "========== [7/8] 生成镜像 =========="
cd "$SDFUSE_DIR"
chmod +x mk-sd-image.sh
rm -f out/*.img
set +e
yes | ./mk-sd-image.sh "$DIST_NAME" > /tmp/mk-sd.log 2>&1
MK_EXIT=$?
set -e
echo "  mk-sd-image.sh exit=$MK_EXIT"
tail -20 /tmp/mk-sd.log | sed 's/^/    /'

FOUND_IMG=$(find out -maxdepth 1 -name "*.img" -print -quit)
[ -z "$FOUND_IMG" ] && { err "未生成镜像"; exit 1; }
mv "$FOUND_IMG" "$OUTPUT_IMG"

# ============================================================
# 8. 验证
# ============================================================
log "========== [8/8] 验证 =========="
KERNEL_OFFSET=$((0x12000 * 512))
python3 - "$OUTPUT_IMG" "$KERNEL_OFFSET" <<'PYEOF'
import sys
img, off = sys.argv[1], int(sys.argv[2])
with open(img, 'rb') as f:
    f.seek(off); d = f.read(128)
assert d[0:4] == b'KRNL', 'KRNL missing'
assert d[0x08:0x0c] == b'\x1f\x20\x03\xd5', 'code0 != NOP'
idx = d.find(b'ARM\x64')
assert idx == 0x40, f'magic @ 0x{idx:x}'
print(f"    KRNL size={int.from_bytes(d[4:8],'little')}  code0={d[0x08:0x0c].hex()}  code1={d[0x0c:0x10].hex()}  magic@0x40")
print("    ✓✓✓")
PYEOF

log "=========================================="
log "✓ 完成 (version $VERSION)"
log "  内核: $SELECTED_VER"
log "  输出: $OUTPUT_IMG ($(($(stat -c%s "$OUTPUT_IMG")/1024/1024)) MiB)"
log "=========================================="