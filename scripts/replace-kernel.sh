#!/bin/bash
# replace-kernel.sh - Flippy 内核 → 官方 KRNL 结构
# 用法: replace-kernel.sh <images.tgz> <sd-fuse目录> <dist_name> <输出img路径>
# 环境变量: KERNEL_VERSION, OFFICIAL_DIR
set -euo pipefail

VERSION="2026-09-11-v25-movx20-signature"
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
# 5. KRNL 构造
# ============================================================
log "[5/7] 构造 kernel.img"

IMAGE_FILE=$(find "$KERNEL_CACHE" -maxdepth 3 -type f -name "vmlinuz-*" | head -1)
[ -z "$IMAGE_FILE" ] && IMAGE_FILE=$(find "$KERNEL_CACHE" -maxdepth 3 -type f -name "Image*" | head -1)
[ -z "$IMAGE_FILE" ] && { err "找不到内核 Image"; exit 1; }
log "  文件: $(basename "$IMAGE_FILE") ($(stat -c%s "$IMAGE_FILE") bytes)"

SYSTEM_MAP=$(find "$KERNEL_CACHE" -maxdepth 3 -type f -name "System.map-*" | head -1)
if [ -n "$SYSTEM_MAP" ]; then
  log "  System.map: $(basename "$SYSTEM_MAP")"
fi

# 抓取官方 KNL（用于对比验证）
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
text_roff = text_s['roff']

# ---------- payload = .text + 其后所有段 ----------
payload_tail = raw[text_s['roff']:]
print("\n  .text 文件偏移=0x%x  大小=%d" % (text_roff, text_s['rsize']))
print("  payload 尾部大小=%d（.text + .data + ...）" % len(payload_tail))
assert len(payload_tail) >= text_s['rsize']

for s in sorted([x for x in secs if x['vaddr'] > text_s['vaddr']], key=lambda x: x['vaddr']):
    print("    + 附加段 %-10s vaddr=0x%08x size=%d" % (s['name'], s['vaddr'], s['rsize']))

# ============================================================
# System.map 仅用于信息性输出
# ============================================================
if sysmap_path and os.path.exists(sysmap_path):
    print("\n  ── System.map 符号（仅供参考，不用于决策） ──")
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
            syms.setdefault(name, []).append(addr)
    for n in ('_text', 'stext', '_stext', 'primary_entry',
              'record_mmu_state', '__primary_switch', '__primary_switched'):
        if n in syms:
            print("  %-20s = %s  (出现 %d 次)" %
                  (n, [hex(a) for a in syms[n][:3]], len(syms[n])))

# ============================================================
# ★ 入口定位：mov x20, x0 指纹
# ============================================================
print("\n  ── 入口定位（mov x20, x0 指纹） ──")

# ARM64: mov x20, x0 编码 = 0xAA0003F4（小端 F4 03 00 AA）
MOV_X20_X0 = struct.pack('<I', 0xAA0003F4)

def is_bl(insn):
    return ((insn >> 26) & 0x3F) == 0x25

def bl_target(off):
    insn = struct.unpack_from('<I', text, off)[0]
    if not is_bl(insn): return None
    imm26 = insn & 0x03FFFFFF
    if imm26 & 0x02000000: imm26 -= 0x04000000
    return off + imm26 * 4

candidates = []
s = 0
while True:
    m = text.find(MOV_X20_X0, s)
    if m < 0: break
    s = m + 1
    # 检查前 8 字节是 2 条 BL，后 4 字节是 BL
    if m < 8 or m + 8 > len(text): continue
    p2 = struct.unpack_from('<I', text, m - 8)[0]   # 第一条 BL (primary_entry[0])
    p1 = struct.unpack_from('<I', text, m - 4)[0]   # 第二条 BL
    n1 = struct.unpack_from('<I', text, m + 4)[0]   # 第三条 BL
    if not (is_bl(p2) and is_bl(p1) and is_bl(n1)):
        continue
    entry_candidate = m - 8
    # 记录第一条 BL 的目标（应为 record_mmu_state）
    tgt = bl_target(entry_candidate)
    candidates.append((entry_candidate, tgt))

print("  mov x20, x0 + 前后 BL 匹配: %d 处" % len(candidates))
for i, (e, t) in enumerate(candidates):
    pct = 100.0 * e / len(text)
    print("    [%d] entry @ .text[0x%08x]  (%.2f%%)  首条 BL 目标 0x%x" %
          (i, e, pct, t if t is not None else 0))

if not candidates:
    print("\n  ✗ 未找到 primary_entry 指纹")
    print("  ── 尝试放宽：只搜 2 条前置 BL + 后置 BL（忽略 mov 编码）──")
    # 放宽策略：搜 BL-BL-?-BL 的组合，第三位为任意 mov 到 x20/x19 的指令
    s = 0
    relax = []
    while s + 16 <= len(text):
        p2 = struct.unpack_from('<I', text, s)[0]
        p1 = struct.unpack_from('<I', text, s+4)[0]
        p0 = struct.unpack_from('<I', text, s+8)[0]
        n1 = struct.unpack_from('<I', text, s+12)[0]
        # mov xN, xM 的编码：0xAA0003E0 | (N<<0)? 简化为 opcode 0x2a 类
        if is_bl(p2) and is_bl(p1) and is_bl(n1):
            # 中间指令 opcode 应为 mov 类 (0x2a, 0x28, 0x29)
            op = (p0 >> 26) & 0x3F
            if op in (0x28, 0x29, 0x2a, 0x2b):
                relax.append(s)
                print("    relax @ .text[0x%08x]  opcode_mid=0x%02x" % (s, op))
        s += 4
    if relax:
        candidates = [(e, bl_target(e)) for e in relax]
    else:
        sys.exit(1)

# 用 System.map 的 record_mmu_state 辅助选择（如果可用）
sysmap_rec_vaddr = None
sysmap_text_vaddr = None
if sysmap_path and os.path.exists(sysmap_path):
    with open(sysmap_path, 'r', errors='ignore') as f:
        for line in f:
            parts = line.split()
            if len(parts) < 3: continue
            try:
                addr = int(parts[0], 16)
            except ValueError:
                continue
            if parts[2] in ('_text', 'stext', '_stext') and sysmap_text_vaddr is None:
                sysmap_text_vaddr = addr
            elif parts[2] == 'record_mmu_state' and sysmap_rec_vaddr is None:
                sysmap_rec_vaddr = addr

    if sysmap_rec_vaddr and sysmap_text_vaddr:
        # 期望 payload 偏移 = (vaddr - _text) - text_roff
        expected_rec_off = (sysmap_rec_vaddr - sysmap_text_vaddr) - text_roff
        print("\n  System.map 推算 record_mmu_state → .text[0x%x]" % expected_rec_off)
        # 特征匹配
        REC_PATTERN = b'\x53\x42\x38\xd5\x7f\x22\x00\xf1'
        rec_idx = text.find(REC_PATTERN)
        if rec_idx >= 0:
            print("  特征匹配 record_mmu_state → .text[0x%x]" % rec_idx)
            if rec_idx == expected_rec_off:
                print("  ✓ System.map 与 Image 一致，可信")
            else:
                print("  ⚠ 不一致（差值 0x%x），System.map 可能与 Image 不匹配" %
                      (rec_idx - expected_rec_off))
        # 用首条 BL 目标与 record_mmu_state 匹配来筛选候选
        filtered = []
        for e, t in candidates:
            if t is not None and abs(t - expected_rec_off) < 0x100:
                filtered.append((e, t))
                print("  ✓ 候选 entry @ 0x%x 的首条 BL 指向 record_mmu_state (0x%x)" % (e, t))
        if filtered:
            candidates = filtered

# 最终选择：如果多个候选，选第一个（.text 位置最靠前的）
entry = candidates[0][0]
entry_method = "mov x20, x0 指纹 + 前后 BL 校验"
print("\n  ★ 最终 entry @ .text[0x%x]  方法: %s" % (entry, entry_method))

# ============================================================
# 交叉验证：反汇编入口 4 条指令
# ============================================================
print("\n  ── 入口交叉验证 ──")
entry_bytes = text[entry:entry+16]
print("  entry 处 16 字节: %s" % entry_bytes.hex())
for i in range(4):
    off = entry + i*4
    insn = struct.unpack_from('<I', text, off)[0]
    op = (insn >> 26) & 0x3F
    if op == 0x25:
        opname = "BL"
    elif op == 0x05:
        opname = "B"
    elif op in (0x28, 0x29, 0x2a, 0x2b):
        opname = "MOV/ORR"
    else:
        opname = "op_0x%02x" % op
    print("    [%d] 0x%08x  opcode=0x%02x (%s)" % (i, insn, op, opname))

expected_hex = "06000094d398e697f40300aa23000094"
if entry_bytes.hex() == expected_hex:
    print("  ✓✓✓ entry 16 字节与官方内核 head.S 完全一致")
else:
    print("  ⚠ entry 16 字节与官方不完全相同（正常：BL imm26 因编译选项不同）")
    # 检查中间 4 字节是否为 mov x20, x0
    mid = text[entry+8:entry+12]
    if mid == MOV_X20_X0:
        print("  ✓ 中间 mov x20, x0 完全匹配")

# ---------- 构造 KRNL ----------
KNL_HDR = 0x10000
payload = payload_tail
target_in_knl = KNL_HDR + entry
rel = target_in_knl - 0x0C
assert rel % 4 == 0
assert -0x8000000 <= rel <= 0x7FFFFFC, "B 偏移越界: 0x%x" % rel
code1 = 0x14000000 | ((rel // 4) & 0x03FFFFFF)
print("\n  code1=0x%08x  B %+d  → KNL[0x%x]" % (code1, rel, target_in_knl))

hdr = bytearray(KNL_HDR)
struct.pack_into('<I', hdr, 0x00, 0x4c4e524b)              # "KRNL"
struct.pack_into('<I', hdr, 0x04, KNL_HDR + len(payload))
struct.pack_into('<I', hdr, 0x08, 0xd503201f)              # code0 = NOP
struct.pack_into('<I', hdr, 0x0C, code1)
struct.pack_into('<Q', hdr, 0x10, 0)
struct.pack_into('<Q', hdr, 0x18, len(payload))
struct.pack_into('<Q', hdr, 0x20, 0x0a)
hdr[0x40:0x44] = b'ARMd'

knl = bytes(hdr) + payload
open(dst, 'wb').write(knl)

# ---------- 严格校验 ----------
zero_region = knl[0x48:0x10000]
assert knl[0:4] == b'KRNL'
assert knl[0x08:0x0c] == b'\x1f\x20\x03\xd5'
assert knl[0x0c:0x10] == struct.pack('<I', code1)
assert knl[0x40:0x44] == b'ARMd'
assert not any(zero_region), "0x48..0x10000 非零"
assert knl[0x10000:0x10004] == text[:4]
assert knl[target_in_knl:target_in_knl+4] == text[entry:entry+4]

print("\n  KNL size              = %d" % len(knl))
print("  payload (.text+.data) = %d" % len(payload))
print("  image_size            = %d" % len(payload))
print("  entry offset          = 0x%x" % entry)
print("  0x48..0x10000         = 零填充 ✓")
print("\n  SUCCESS")
PYEOF

# ============================================================
# 5.5 扩容 kernel 分区
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
  warn "  ✗ uInitrd 未找到"
fi

# ============================================================
# 7. 生成镜像（pipefail 修复）
# ============================================================
log "[7/7] 生成镜像"
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
# 最终验证
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