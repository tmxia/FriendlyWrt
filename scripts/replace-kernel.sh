#!/bin/bash
# replace-kernel.sh - Flippy 内核 → 官方 KRNL 结构（完整版）
# 用法: replace-kernel.sh <images.tgz> <sd-fuse目录> <dist_name> <输出img路径>
# 环境变量: KERNEL_VERSION, OFFICIAL_DIR
set -euo pipefail

VERSION="2026-09-11-v21-complete"
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
log "[1/7] 解压 images.tgz"
mkdir -p "$WORK_DIR/base"
tar xzf "$IMAGES_TGZ" -C "$WORK_DIR/base"
BASE_DIR=$(find "$WORK_DIR/base" -maxdepth 2 -type d -name "friendlywrt*" | head -1)
[ -z "$BASE_DIR" ] && { err "找不到顶层目录"; exit 1; }

# ============================================================
# 2. 扫描内核
# ============================================================
log "[2/7] 扫描 $KERNEL_VERSION"
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
log "[3/7] 下载内核"
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
log "[4/7] 复制骨架"
TARGET_DIR="$SDFUSE_DIR/$DIST_NAME"
rm -rf "$TARGET_DIR"
cp -a "$BASE_DIR" "$TARGET_DIR"

# ============================================================
# 5. KRNL 构造（完整 PE → KRNL，含 .data）
# ============================================================
log "[5/7] 构造 kernel.img"

IMAGE_FILE=$(find "$KERNEL_CACHE" -maxdepth 3 -type f -name "vmlinuz-*" | head -1)
[ -z "$IMAGE_FILE" ] && IMAGE_FILE=$(find "$KERNEL_CACHE" -maxdepth 3 -type f -name "Image*" | head -1)
[ -z "$IMAGE_FILE" ] && { err "找不到内核 Image"; exit 1; }
log "  文件: $(basename "$IMAGE_FILE") ($(stat -c%s "$IMAGE_FILE") bytes)"

# 提取官方 KRNL 头（用于动态对比，不硬编码）
OFFICIAL_HEAD="$WORK_DIR/official_krnl_head.bin"
OFFICIAL_IMG=$(find "$OFFICIAL_DIR" -maxdepth 1 -name "*.img" 2>/dev/null | head -1 || true)
if [ -n "$OFFICIAL_IMG" ] && [ -f "$OFFICIAL_IMG" ]; then
  python3 - "$OFFICIAL_IMG" "$OFFICIAL_HEAD" <<'EXTRACT' || true
import sys
img, out = sys.argv[1], sys.argv[2]
with open(img, 'rb') as f:
    buf = f.read(4 * 1024 * 1024)
idx = buf.find(b'KRNL')
if idx >= 0:
    open(out, 'wb').write(buf[idx:idx + 0x10000])
    print(f"  官方 KRNL @ 0x{idx:x}")
else:
    sys.exit(1)
EXTRACT
fi

python3 - "$IMAGE_FILE" "$TARGET_DIR/kernel.img" "$OFFICIAL_HEAD" <<'PYEOF'
import sys, struct, os

src, dst = sys.argv[1], sys.argv[2]
off_head_path = sys.argv[3] if len(sys.argv) > 3 else None
raw = open(src, 'rb').read()

# ---------- 输入校验 ----------
if raw[:4] == b'KRNL':
    open(dst, 'wb').write(raw); print("  已是 KRNL"); sys.exit(0)
if raw[:2] != b'MZ':
    idx = raw.find(b'ARM\x64')
    if idx == 0x38 and raw[0:4] == b'\x1f\x20\x03\xd5':
        open(dst, 'wb').write(b'KRNL' + struct.pack('<I', len(raw)) + raw)
        print("  裸机 Image 直接封装"); sys.exit(0)
    print("  未知格式"); sys.exit(1)

# ---------- PE 解析 ----------
pe_off = struct.unpack_from('<I', raw, 0x3C)[0]
assert raw[pe_off:pe_off+4] == b'PE\x00\x00', "PE 签名错误"
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

# ---------- 关键修复①：payload = .text + 其后所有段 ----------
payload_tail = raw[text_s['roff']:]
print("\n  .text 文件偏移=0x%x  大小=%d" % (text_s['roff'], text_s['rsize']))
print("  payload 尾部大小=%d（.text + .data + ...）" % len(payload_tail))
assert len(payload_tail) >= text_s['rsize'], "payload 尾部小于 .text，文件损坏"

after = sorted([s for s in secs if s['vaddr'] > text_s['vaddr']], key=lambda x: x['vaddr'])
for s in after:
    print("    + 附加段 %-10s vaddr=0x%08x size=%d" % (s['name'], s['vaddr'], s['rsize']))

# ---------- 关键修复②：定位真正的 primary_entry ----------
PATTERN = b'\x53\x42\x38\xd5\x7f\x22\x00\xf1'   # mrs x19, CurrentEL; cmp x19, #8
rec = text.find(PATTERN)
assert rec >= 0, "未找到 record_mmu_state 特征"
print("\n  record_mmu_state @ .text[0x%x]" % rec)

entry = rec
if rec >= 4:
    prev = struct.unpack_from('<I', text, rec - 4)[0]
    if (prev & 0xFC000000) == 0x94000000:          # BL 指令
        imm26 = prev & 0x03FFFFFF
        if imm26 & 0x02000000: imm26 -= 0x04000000
        tgt = (rec - 4) + imm26 * 4
        if rec <= tgt <= rec + 16:
            entry = rec - 4
            print("  ★ primary_entry @ .text[0x%x] (通过前置 BL 回溯)" % entry)
print("  ★ 使用入口 @ .text[0x%x]" % entry)

# ---------- 构造 KRNL ----------
KNL_HDR = 0x10000
payload = payload_tail
target_in_knl = KNL_HDR + entry
rel = target_in_knl - 0x0C
assert rel % 4 == 0
assert -0x8000000 <= rel <= 0x7FFFFFC, "B 偏移越界: 0x%x" % rel
code1 = 0x14000000 | ((rel // 4) & 0x03FFFFFF)
print("  code1=0x%08x  B %+d  → KNL[0x%x]" % (code1, rel, target_in_knl))

hdr = bytearray(KNL_HDR)
struct.pack_into('<I', hdr, 0x00, 0x4c4e524b)              # "KRNL"
struct.pack_into('<I', hdr, 0x04, KNL_HDR + len(payload))  # 含头大小的总长
struct.pack_into('<I', hdr, 0x08, 0xd503201f)              # code0 = NOP
struct.pack_into('<I', hdr, 0x0C, code1)
struct.pack_into('<Q', hdr, 0x10, 0)
struct.pack_into('<Q', hdr, 0x18, len(payload))            # image_size
struct.pack_into('<Q', hdr, 0x20, 0x0a)
hdr[0x40:0x44] = b'ARMd'

knl = bytes(hdr) + payload
open(dst, 'wb').write(knl)

# ---------- 严格校验 ----------
zero_region = knl[0x48:0x10000]
assert knl[0:4] == b'KRNL', "KRNL magic 错误"
assert knl[0x08:0x0c] == b'\x1f\x20\x03\xd5', "code0 不是 NOP"
assert knl[0x0c:0x10] == struct.pack('<I', code1), "code1 写入错误"
assert knl[0x40:0x44] == b'ARMd', "ARM64 magic 位置错误"
assert not any(zero_region), "0x48..0x10000 必须零填充（%d 字节非零）" % sum(zero_region)
assert knl[0x10000:0x10004] == text[:4], "payload 起点错误"
assert knl[target_in_knl:target_in_knl+4] == text[entry:entry+4], "code1 目标未命中入口"

print("\n" + "=" * 70)
print("结果")
print("=" * 70)
print("  KNL size              = %d" % len(knl))
print("  payload (.text+.data) = %d" % len(payload))
print("  image_size            = %d" % len(payload))
print("  entry offset          = 0x%x  (%s)" %
      (entry, "primary_entry" if entry < rec else "record_mmu_state"))
print("  0x48..0x10000         = 零填充 ✓")

if off_head_path and os.path.exists(off_head_path):
    off = open(off_head_path, 'rb').read(0x10000)
    print("\n  ── 与官方 KRNL 头动态对比 ──")
    print("  字段        自建          官方")
    print("  [0x00]      %s      %s" % (knl[0:4], off[0:4]))
    print("  [0x08]      %s      %s" % (knl[0x08:0x0c].hex(), off[0x08:0x0c].hex()))
    print("  [0x40]      %s      %s" % (knl[0x40:0x44], off[0x40:0x44]))
    print("  [0x04]size  %-12d  %d" % (
        struct.unpack_from('<I', knl, 4)[0],
        struct.unpack_from('<I', off, 4)[0]))
    print("  [0x18]imgsz 0x%-11x 0x%x" % (
        struct.unpack_from('<Q', knl, 0x18)[0],
        struct.unpack_from('<Q', off, 0x18)[0]))
    off_code1 = struct.unpack_from('<I', off, 0x0C)[0]
    assert (code1 >> 26) == (off_code1 >> 26), "code1 opcode 与官方不一致"

print("\n  SUCCESS")
PYEOF

# ============================================================
# 5.5 从 parameter.txt 动态解析 kernel 分区并扩容
# ============================================================
log "[5.5/7] 扩容 kernel 分区"
PARAM_FILE="$TARGET_DIR/parameter.txt"
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
print("[param] old=%.1f MiB  need=%.1f MiB  new=%.1f MiB" %
      (old_size*512/1024/1024, need*512/1024/1024, new_size*512/1024/1024))
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
print(f"[param] 已扩容 delta={delta} sectors")
PARAM_PYEOF

# ============================================================
# 6. dtb + uInitrd
# ============================================================
log "[6/7] dtb + uInitrd"
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
  warn "  ✗ uInitrd 未找到（boot 可能失败）"
fi

# ============================================================
# 7. 生成镜像
# ============================================================
log "[7/7] 生成镜像"
cd "$SDFUSE_DIR"
chmod +x mk-sd-image.sh
rm -f out/*.img
set +e
yes | ./mk-sd-image.sh "$DIST_NAME" > /tmp/mk-sd.log 2>&1
MK_EXIT=$?
set -e
[ $MK_EXIT -ne 0 ] && { err "mk-sd-image.sh 失败:"; tail -50 /tmp/mk-sd.log; exit 1; }
FOUND_IMG=$(find out -maxdepth 1 -name "*.img" -print -quit)
[ -z "$FOUND_IMG" ] && { err "未生成镜像"; exit 1; }
mv "$FOUND_IMG" "$OUTPUT_IMG"

# ============================================================
# 最终验证：从 parameter.txt 动态读取偏移
# ============================================================
KERNEL_OFFSET=$(grep -oE '0x[0-9a-fA-F]+@0x[0-9a-fA-F]+\(kernel\)' "$PARAM_FILE" \
  | head -1 | sed -E 's/.*@(0x[0-9a-fA-F]+)\(kernel\)/\1/')
KERNEL_BYTE_OFF=$(( KERNEL_OFFSET * 512 ))
log "  验证: kernel 分区 @ 0x${KERNEL_OFFSET#0x} 扇区 = $KERNEL_BYTE_OFF 字节"

python3 - "$OUTPUT_IMG" "$KERNEL_BYTE_OFF" <<'PYEOF'
import sys, struct
img, off = sys.argv[1], int(sys.argv[2])
with open(img, 'rb') as f:
    f.seek(off); d = f.read(0x10010)
assert d[0:4] == b'KRNL', "KRNL magic 缺失 @ 0x%x" % off
assert d[0x08:0x0c] == b'\x1f\x20\x03\xd5', "code0 != NOP"
assert d[0x40:0x44] == b'ARM\x64', "ARM64 magic 位置错误"
assert d[0x48:0x10000] == b'\x00' * (0x10000 - 0x48), "0x48..0x10000 非零填充"
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