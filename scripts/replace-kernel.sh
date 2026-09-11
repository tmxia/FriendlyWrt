#!/bin/bash
# replace-kernel.sh - Flippy 内核 + 模块注入 → 官方 KRNL 结构
# 用法: replace-kernel.sh <images.tgz> <sd-fuse目录> <dist_name> <输出img路径>
# 环境变量: KERNEL_VERSION, OFFICIAL_DIR
set -euo pipefail

VERSION="2026-09-11-v27-all-in-one"
log()  { echo -e "\033[0;32m[replace]\033[0m $*"; }
warn() { echo -e "\033[0;33m[replace]\033[0m $*"; }
err()  { echo -e "\033[0;31m[replace]\033[0m $*" >&2; }
log "replace-kernel.sh version: $VERSION"

IMAGES_TGZ="${1:?}"; SDFUSE_DIR="${2:?}"; DIST_NAME="${3:?}"; OUTPUT_IMG="${4:?}"
KERNEL_VERSION="${KERNEL_VERSION:-6.18.y}"
OFFICIAL_DIR="${OFFICIAL_DIR:-/tmp/official}"

WORK_DIR=$(mktemp -d /tmp/replace-kernel.XXXXXX)
trap "rm -rf $WORK_DIR" EXIT

# ============================================================
# 1. 解压 images.tgz
# ============================================================
log "[1/8] 解压 images.tgz"
mkdir -p "$WORK_DIR/base"
tar xzf "$IMAGES_TGZ" -C "$WORK_DIR/base"
BASE_DIR=$(find "$WORK_DIR/base" -maxdepth 2 -type d -name "friendlywrt*" | head -1)
[ -z "$BASE_DIR" ] && { err "找不到顶层目录"; exit 1; }

# ============================================================
# 2. 扫描内核
# ============================================================
log "[2/8] 扫描 $KERNEL_VERSION"
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
# 3. 下载内核（带缓存）
# ============================================================
log "[3/8] 下载内核"
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
log "[4/8] 复制骨架"
TARGET_DIR="$SDFUSE_DIR/$DIST_NAME"
rm -rf "$TARGET_DIR"
cp -a "$BASE_DIR" "$TARGET_DIR"

# ============================================================
# 5. KRNL 构造
# ============================================================
log "[5/8] 构造 kernel.img"

IMAGE_FILE=$(find "$KERNEL_CACHE" -maxdepth 3 -type f -name "vmlinuz-*" | head -1)
[ -z "$IMAGE_FILE" ] && IMAGE_FILE=$(find "$KERNEL_CACHE" -maxdepth 3 -type f -name "Image*" | head -1)
[ -z "$IMAGE_FILE" ] && { err "找不到内核 Image"; exit 1; }
log "  文件: $(basename "$IMAGE_FILE") ($(stat -c%s "$IMAGE_FILE") bytes)"

SYSTEM_MAP=$(find "$KERNEL_CACHE" -maxdepth 3 -type f -name "System.map-*" | head -1)
[ -n "$SYSTEM_MAP" ] && log "  System.map: $(basename "$SYSTEM_MAP")"
[ -z "$SYSTEM_MAP" ] && { err "无 System.map，无法可靠定位入口"; exit 1; }

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
    print("  官方 KNL @ 0x%x, 抓取 %d 字节" % (idx, end - idx))
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
    open(dst, 'wb').write(raw); print("  已是 KRNL"); sys.exit(0)
if raw[:2] != b'MZ':
    idx = raw.find(b'ARM\x64')
    if idx == 0x38 and raw[0:4] == b'\x1f\x20\x03\xd5':
        open(dst, 'wb').write(b'KRNL' + struct.pack('<I', len(raw)) + raw)
        print("  裸机 Image 直接封装"); sys.exit(0)
    print("  未知格式"); sys.exit(1)

pe_off = struct.unpack_from('<I', raw, 0x3C)[0]
assert raw[pe_off:pe_off+4] == b'PE\x00\x00'
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
    print("  %-10s vaddr=0x%08x off=0x%08x rsize=%d vsize=%d"
          % (name, vaddr, roff, rsize, vsize))

text_s = next(s for s in secs if s['name'] == '.text')
text = raw[text_s['roff']: text_s['roff'] + text_s['rsize']]
text_roff = text_s['roff']
payload_tail = raw[text_s['roff']:]
print("\n  .text 文件偏移=0x%x  大小=%d" % (text_roff, text_s['rsize']))
print("  payload 尾部大小=%d" % len(payload_tail))
assert len(payload_tail) >= text_s['rsize']
for s in sorted([x for x in secs if x['vaddr'] > text_s['vaddr']], key=lambda x: x['vaddr']):
    print("    + 附加段 %-10s vaddr=0x%08x size=%d" % (s['name'], s['vaddr'], s['rsize']))

print("\n  ══════ System.map 符号解析 ══════")
syms = {}
with open(sysmap_path, 'r', errors='ignore') as f:
    for line in f:
        parts = line.split()
        if len(parts) < 3: continue
        try:
            addr = int(parts[0], 16)
        except ValueError:
            continue
        name = parts[2]
        if name not in syms:
            syms[name] = addr

_text  = syms.get('_text')
primary = syms.get('primary_entry')
rec_mmu = syms.get('record_mmu_state')
p_switch = syms.get('__primary_switch')

for n, v in [('_text', _text), ('primary_entry', primary),
             ('record_mmu_state', rec_mmu), ('__primary_switch', p_switch)]:
    print("  %-20s = %s" % (n, hex(v) if v else "N/A"))

if not _text:
    print("  ✗ 缺少 _text"); sys.exit(1)

def v2p(vaddr):
    return vaddr - _text - text_roff

REC_PATTERN = b'\x53\x42\x38\xd5\x7f\x22\x00\xf1'
rec_feature = text.find(REC_PATTERN)
rec_off = None
if rec_mmu:
    rec_off_sysmap = v2p(rec_mmu)
    print("\n  record_mmu_state → payload[0x%x]" % rec_off_sysmap)
    if rec_feature >= 0:
        print("  特征匹配 record_mmu_state → .text[0x%x]" % rec_feature)
        if rec_off_sysmap == rec_feature:
            print("  ✓ 一致，映射公式正确")
            rec_off = rec_feature
        else:
            rec_off = rec_feature
    else:
        rec_off = rec_off_sysmap

def insn_at(off):
    if off < 0 or off + 4 > len(text): return None
    return struct.unpack_from('<I', text, off)[0]

def is_bl(v):
    return v is not None and ((v >> 26) & 0x3F) == 0x25

def bl_target(off):
    v = insn_at(off)
    if not is_bl(v): return None
    imm = v & 0x03FFFFFF
    if imm & 0x02000000: imm -= 0x04000000
    return off + imm * 4

print("\n  ══════ 入口定位 ══════")
entry = None
entry_method = None

if primary:
    e = v2p(primary)
    print("  [A] System.map primary_entry → payload[0x%x]" % e)
    if 0 <= e < len(text) - 16:
        entry_bytes = text[e:e+16]
        print("      16 字节: %s" % entry_bytes.hex())
        if any(entry_bytes):
            first = insn_at(e)
            op = (first >> 26) & 0x3F
            print("      首指令 opcode=0x%02x" % op)
            if op == 0x25 and rec_off is not None:
                tgt = bl_target(e)
                print("      首条 BL 目标 = payload[0x%x]  (record_mmu_state @ 0x%x)" % (tgt, rec_off))
                if tgt == rec_off:
                    print("      ✓✓✓ 首条 BL 目标 = record_mmu_state，验证通过")
                    entry = e
                    entry_method = "System.map primary_entry（BL→record_mmu 验证通过）"
            elif op in (0x25, 0x05):
                entry = e
                entry_method = "System.map primary_entry（首指令 BL/B）"

if entry is None and rec_off is not None:
    print("  [B] BL 反查 record_mmu_state")
    for i in range(max(0, rec_off - 0x200), rec_off, 4):
        if bl_target(i) == rec_off:
            print("      找到 BL @ payload[0x%x]" % i)
            bl_count = sum(1 for k in range(4) if is_bl(insn_at(i + k*4)))
            print("      前 4 条 BL 数量: %d" % bl_count)
            if bl_count >= 2:
                entry = i
                entry_method = "BL 反查 + 前 4 条 BL≥2"
                break

if entry is None:
    print("  ✗ 所有策略失败"); sys.exit(1)

print("\n  ══════ 入口交叉验证 ══════")
print("  entry = payload[0x%x]  方法: %s" % (entry, entry_method))
print("  entry 16 字节: %s" % text[entry:entry+16].hex())
for i in range(4):
    off = entry + i*4
    v = insn_at(off)
    if v is None: break
    op = (v >> 26) & 0x3F
    if op == 0x25:
        name = "BL → 0x%x" % bl_target(off)
    elif op == 0x05:
        imm = v & 0x03FFFFFF
        if imm & 0x02000000: imm -= 0x04000000
        name = "B → 0x%x" % (off + imm * 4)
    elif op in (0x28, 0x29, 0x2a, 0x2b):
        name = "MOV/ORR"
    else:
        name = "op_0x%02x" % op
    print("    [%d] 0x%08x  %s" % (i, v, name))

KNL_HDR = 0x10000
payload = payload_tail
target_in_knl = KNL_HDR + entry
rel = target_in_knl - 0x0C
assert rel % 4 == 0
assert -0x8000000 <= rel <= 0x7FFFFFC, "B 偏移越界"
code1 = 0x14000000 | ((rel // 4) & 0x03FFFFFF)
print("\n  code1=0x%08x  B %+d  → KNL[0x%x]" % (code1, rel, target_in_knl))

hdr = bytearray(KNL_HDR)
struct.pack_into('<I', hdr, 0x00, 0x4c4e524b)
struct.pack_into('<I', hdr, 0x04, KNL_HDR + len(payload))
struct.pack_into('<I', hdr, 0x08, 0xd503201f)
struct.pack_into('<I', hdr, 0x0C, code1)
struct.pack_into('<Q', hdr, 0x10, 0)
struct.pack_into('<Q', hdr, 0x18, len(payload))
struct.pack_into('<Q', hdr, 0x20, 0x0a)
hdr[0x40:0x44] = b'ARMd'

knl = bytes(hdr) + payload
open(dst, 'wb').write(knl)

zero_region = knl[0x48:0x10000]
assert knl[0:4] == b'KRNL'
assert knl[0x08:0x0c] == b'\x1f\x20\x03\xd5'
assert knl[0x0c:0x10] == struct.pack('<I', code1)
assert knl[0x40:0x44] == b'ARMd'
assert not any(zero_region)
assert knl[0x10000:0x10004] == text[:4]
assert knl[target_in_knl:target_in_knl+4] == text[entry:entry+4]

print("\n  KNL size              = %d" % len(knl))
print("  payload (.text+.data) = %d" % len(payload))
print("  entry offset          = 0x%x" % entry)
print("  0x48..0x10000         = 零填充 ✓")
print("\n  SUCCESS")
PYEOF

# ============================================================
# 5.3 注入内核模块到 rootfs.img
# ============================================================
log "[5.3/8] 注入内核模块到 rootfs.img"

MODULES_TAR=$(find "$KERNEL_CACHE" -maxdepth 2 -name "modules-*.tar.gz" | head -1)
ROOTFS_IMG="$TARGET_DIR/rootfs.img"
PARAM_FILE="$TARGET_DIR/parameter.txt"

[ -z "$MODULES_TAR" ] && { err "  未找到 modules-*.tar.gz"; exit 1; }
[ ! -f "$ROOTFS_IMG" ] && { err "  rootfs.img 不存在"; exit 1; }
[ ! -f "$PARAM_FILE" ] && { err "  parameter.txt 不存在"; exit 1; }

command -v unsquashfs >/dev/null || { err "  缺少 unsquashfs（请装 squashfs-tools）"; exit 1; }
command -v mksquashfs >/dev/null || { err "  缺少 mksquashfs（请装 squashfs-tools）"; exit 1; }

log "  modules: $(basename "$MODULES_TAR") ($(stat -c%s "$MODULES_TAR") bytes)"
log "  rootfs:  $(stat -c%s "$ROOTFS_IMG") bytes"

MOD_EX="$WORK_DIR/modules_extract"
mkdir -p "$MOD_EX"
tar xzf "$MODULES_TAR" -C "$MOD_EX"

MOD_LIB=$(find "$MOD_EX" -maxdepth 5 -type d -path "*/lib/modules/6.*" | head -1)
[ -z "$MOD_LIB" ] && MOD_LIB=$(find "$MOD_EX" -maxdepth 5 -type d -name "6.*" | head -1)
[ -z "$MOD_LIB" ] && { err "  模块目录未找到"; find "$MOD_EX" -maxdepth 3 -type d | head; exit 1; }
KVER=$(basename "$MOD_LIB")
KO_COUNT=$(find "$MOD_LIB" -name "*.ko*" 2>/dev/null | wc -l)
log "  内核版本: $KVER"
log "  模块数:   $KO_COUNT"
[ "$KO_COUNT" -lt 10 ] && { err "  模块数过少（$KO_COUNT）"; exit 1; }

ROOTFS_FMT=$(file -b "$ROOTFS_IMG")
log "  rootfs 格式: $ROOTFS_FMT"
if ! echo "$ROOTFS_FMT" | grep -qi "squashfs"; then
  err "  只支持 squashfs（实际: $ROOTFS_FMT）"
  exit 1
fi

COMP=$(unsquashfs -s "$ROOTFS_IMG" 2>/dev/null | grep -i 'compression' | awk '{print tolower($2)}')
[ -z "$COMP" ] && COMP="xz"
log "  压缩算法: $COMP"
case "$COMP" in
  gzip) MK_COMP="-comp gzip" ;;
  lzo)  MK_COMP="-comp lzo"  ;;
  lz4)  MK_COMP="-comp lz4"  ;;
  xz)   MK_COMP="-comp xz"   ;;
  zstd) MK_COMP="-comp zstd" ;;
  *)    MK_COMP="-comp xz"   ;;
esac

ROOT_EX="$WORK_DIR/rootfs_extract"
mkdir -p "$ROOT_EX"
log "  解包 squashfs（1-3 分钟）..."
set +e
unsquashfs -d "$ROOT_EX" -no-progress "$ROOTFS_IMG" > "$WORK_DIR/unsquashfs.log" 2>&1
UNSQ_RC=$?
set -e
[ $UNSQ_RC -ne 0 ] && { err "  unsquashfs 失败:"; tail -20 "$WORK_DIR/unsquashfs.log"; exit 1; }

EXISTING=$(ls "$ROOT_EX/lib/modules/" 2>/dev/null | tr '\n' ' ' || echo "(空)")
log "  现有 /lib/modules: $EXISTING"

mkdir -p "$ROOT_EX/lib/modules/$KVER"
cp -a "$MOD_LIB/." "$ROOT_EX/lib/modules/$KVER/"
INJECTED=$(find "$ROOT_EX/lib/modules/$KVER" -name '*.ko*' 2>/dev/null | wc -l)
log "  已注入: $INJECTED 个模块"

ROOTFS_NEW="$WORK_DIR/rootfs.img.new"
log "  重打包 squashfs（2-5 分钟）..."
set +e
mksquashfs "$ROOT_EX" "$ROOTFS_NEW" $MK_COMP -b 128K -noappend -no-progress > "$WORK_DIR/mksquashfs.log" 2>&1
MKSQ_RC=$?
set -e
[ $MKSQ_RC -ne 0 ] && { err "  mksquashfs 失败:"; tail -20 "$WORK_DIR/mksquashfs.log"; exit 1; }

ORIG_SIZE=$(stat -c%s "$ROOTFS_IMG")
NEW_SIZE=$(stat -c%s "$ROOTFS_NEW")
log "  原大小: $ORIG_SIZE bytes ($(python3 -c "print(f'{$ORIG_SIZE/1024/1024:.1f}')") MiB)"
log "  新大小: $NEW_SIZE bytes ($(python3 -c "print(f'{$NEW_SIZE/1024/1024:.1f}')") MiB)"

if ! unsquashfs -l "$ROOTFS_NEW" 2>/dev/null | grep -q "lib/modules/$KVER/"; then
  err "  重打包校验失败"
  exit 1
fi
log "  ✓ 重打包校验通过"

ROOTFS_PART=$(grep -oE '0x[0-9a-fA-F]+@0x[0-9a-fA-F]+\(rootfs\)' "$PARAM_FILE" | head -1)
if [ -n "$ROOTFS_PART" ]; then
  PART_SECTORS=$(echo "$ROOTFS_PART" | sed -E 's/0x([0-9a-fA-F]+)@.*/\1/')
  PART_BYTES=$(( 0x$PART_SECTORS * 512 ))
  log "  parameter.txt rootfs 分区: $PART_SECTORS sectors = $PART_BYTES bytes"

  if [ "$NEW_SIZE" -gt "$PART_BYTES" ]; then
    warn "  新 rootfs 超出分区，扩展 parameter.txt..."
    python3 - "$PARAM_FILE" "$NEW_SIZE" <<'PARAM_EXPAND'
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
print(f"[param] rootfs: {old_size*512/1024/1024:.1f}MiB → {new_size*512/1024/1024:.1f}MiB (delta={delta})")
content = content[:m.start()] + f'0x{new_size:08x}@{m.group(2)}(rootfs)' + content[m.end():]
def shift(mt):
    off = int(mt.group(1), 16)
    return f'@0x{off + delta:08x}' if off >= rootfs_end else mt.group(0)
content = re.sub(r'@0x([0-9a-fA-F]+)', shift, content)
open(param_file, 'w').write(content)
print(f"[param] 已调整")
PARAM_EXPAND
    ROOTFS_PART=$(grep -oE '0x[0-9a-fA-F]+@0x[0-9a-fA-F]+\(rootfs\)' "$PARAM_FILE" | head -1)
    PART_SECTORS=$(echo "$ROOTFS_PART" | sed -E 's/0x([0-9a-fA-F]+)@.*/\1/')
    PART_BYTES=$(( 0x$PART_SECTORS * 512 ))
    log "  新分区大小: $PART_BYTES bytes"
  fi

  mv "$ROOTFS_IMG" "$ROOTFS_IMG.orig"
  mv "$ROOTFS_NEW" "$ROOTFS_IMG"
  rm -f "$ROOTFS_IMG.orig"
  if [ "$(stat -c%s "$ROOTFS_IMG")" -lt "$PART_BYTES" ]; then
    truncate -s "$PART_BYTES" "$ROOTFS_IMG"
    log "  已补齐到分区大小: $PART_BYTES bytes"
  fi
  log "  ✓ rootfs.img 替换完成"
else
  warn "  无 rootfs 分区定义，直接替换"
  mv "$ROOTFS_IMG" "$ROOTFS_IMG.orig"
  mv "$ROOTFS_NEW" "$ROOTFS_IMG"
  rm -f "$ROOTFS_IMG.orig"
fi

# ============================================================
# 5.5 扩容 kernel 分区
# ============================================================
log "[5.5/8] 扩容 kernel 分区"
python3 - "$PARAM_FILE" "$(stat -c%s "$TARGET_DIR/kernel.img")" <<'PARAM_PYEOF'
import re, sys
param_file, kernel_size = sys.argv[1], int(sys.argv[2])
with open(param_file) as f:
    content = f.read()
m = re.search(r'0x([0-9a-fA-F]+)@(0x[0-9a-fA-F]+)\(kernel\)', content, re.IGNORECASE)
if not m:
    print("[param] 未找到 kernel 分区"); sys.exit(0)
old_size = int(m.group(1), 16)
kernel_off = int(m.group(2), 16)
kernel_end = kernel_off + old_size
need = (kernel_size + 511) // 512
rounded = ((need + 0x3FFF) // 0x4000) * 0x4000
new_size = max(rounded, old_size)
print("[param] kernel: old=%.1f MiB  need=%.1f MiB  new=%.1f MiB" %
      (old_size*512/1024/1024, need*512/1024/1024, new_size*512/1024/1024))
if new_size == old_size:
    print("[param] kernel 无需扩容"); sys.exit(0)
delta = new_size - old_size
content = content[:m.start()] + f'0x{new_size:08x}@{m.group(2)}(kernel)' + content[m.end():]
def shift(mt):
    off = int(mt.group(1), 16)
    return f'@0x{off + delta:08x}' if off >= kernel_end else mt.group(0)
content = re.sub(r'@0x([0-9a-fA-F]+)', shift, content)
with open(param_file, 'w') as f:
    f.write(content)
print(f"[param] kernel 已扩容 delta={delta} sectors")
PARAM_PYEOF

# ============================================================
# 6. dtb + uInitrd
# ============================================================
log "[6/8] dtb + uInitrd"
DTB_TAR=$(find "$KERNEL_CACHE" -maxdepth 2 -name "dtb-rockchip-*.tar.gz" | head -1)
if [ -n "$DTB_TAR" ]; then
  mkdir -p "$TARGET_DIR/dtb/rockchip"
  for board in r5s r5c; do
    ENTRY=$(tar tzf "$DTB_TAR" | grep -E "(^|/)rk3568-nanopi-${board}\.dtb$" | head -1 || echo "")
    if [ -n "$ENTRY" ]; then
      tar xzf "$DTB_TAR" -C "$WORK_DIR" "$ENTRY"
      cp "$WORK_DIR/$ENTRY" "$TARGET_DIR/dtb/rockchip/rk3568-nanopi-${board}.dtb"
      log "  ✓ $board dtb"
    else
      warn "  ✗ $board dtb 未找到"
    fi
  done
fi
UINITRD=$(find "$KERNEL_CACHE" -type f -name "uInitrd-*" | head -1)
if [ -n "$UINITRD" ]; then
  cp "$UINITRD" "$TARGET_DIR/uInitrd"; log "  ✓ uInitrd"
else
  warn "  ✗ uInitrd 未找到"
fi

# ============================================================
# 7. 生成镜像
# ============================================================
log "[7/8] 生成镜像"
cd "$SDFUSE_DIR"
chmod +x mk-sd-image.sh
rm -f out/*.img

set +e
set +o pipefail
yes 2>/dev/null | ./mk-sd-image.sh "$DIST_NAME" > /tmp/mk-sd.log 2>&1
MK_EXIT=$?
set -o pipefail
set -e

FOUND_IMG=$(find out -maxdepth 1 -name "*.img" -print -quit)
if [ -z "$FOUND_IMG" ]; then
  err "mk-sd-image.sh 未生成镜像 (exit=$MK_EXIT)，日志尾部:"
  tail -50 /tmp/mk-sd.log
  exit 1
fi
log "  镜像已生成: $FOUND_IMG ($(stat -c%s "$FOUND_IMG") bytes)"
mv "$FOUND_IMG" "$OUTPUT_IMG"

# ============================================================
# 8. 最终验证
# ============================================================
log "[8/8] 最终验证"

KERNEL_OFFSET=$(grep -oE '0x[0-9a-fA-F]+@0x[0-9a-fA-F]+\(kernel\)' "$PARAM_FILE" \
  | head -1 | sed -E 's/.*@(0x[0-9a-fA-F]+)\(kernel\)/\1/')
KERNEL_BYTE_OFF=$(( KERNEL_OFFSET * 512 ))
log "  kernel 分区 @ 0x${KERNEL_OFFSET#0x} 扇区 = $KERNEL_BYTE_OFF 字节"

python3 - "$OUTPUT_IMG" "$KERNEL_BYTE_OFF" <<'PYEOF'
import sys, struct
img, off = sys.argv[1], int(sys.argv[2])
with open(img, 'rb') as f:
    f.seek(off); d = f.read(0x10010)
assert d[0:4] == b'KRNL', "KRNL magic 缺失"
assert d[0x08:0x0c] == b'\x1f\x20\x03\xd5', "code0 != NOP"
assert d[0x40:0x44] == b'ARM\x64', "ARM64 magic 位置错误"
assert d[0x48:0x10000] == b'\x00' * (0x10000 - 0x48), "0x48..0x10000 非零"
size = struct.unpack_from('<I', d, 4)[0]
code1 = struct.unpack_from('<I', d, 0x0C)[0]
imm26 = code1 & 0x03FFFFFF
if imm26 & 0x02000000: imm26 -= 0x04000000
target = 0x0C + imm26 * 4
print("  KRNL size=%d  code0=%s  code1=%s" % (size, d[0x08:0x0c].hex(), d[0x0c:0x10].hex()))
print("  code1 → 0x%x (payload @ 0x10000)" % target)
print("  ✓✓✓")
PYEOF

log "完成 (version $VERSION, 内核 $SELECTED_VER)"