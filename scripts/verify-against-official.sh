#!/bin/bash
# verify-against-official.sh
# 对比自建固件与官方固件的 KRNL 结构，关键项不一致则 exit 1
# 用法: verify-against-official.sh <自建img> <官方目录> [内核版本]
set -uo pipefail

SELF_IMG="$1"
OFFICIAL_DIR="$2"
KERNEL_VER="${3:-unknown}"

echo "════════════════════════════════════════════════════════"
echo "  固件验证：自建 vs 官方（kernel=$KERNEL_VER）"
echo "════════════════════════════════════════════════════════"
echo "  自建:   $SELF_IMG"
echo "  官方目录: $OFFICIAL_DIR"
echo ""

PASS=0; FAIL=0
ok()   { echo "  ✅ $*"; PASS=$((PASS+1)); }
bad()  { echo "  ❌ $*"; FAIL=$((FAIL+1)); }
warn() { echo "  ⚠️  $*"; }

[ ! -f "$SELF_IMG" ] && { echo "❌ 自建镜像不存在"; exit 2; }

SELF_SIZE=$(stat -c%s "$SELF_IMG")
echo "自建镜像大小: $SELF_SIZE bytes"
echo ""

PARAM=$(dirname "$SELF_IMG")/parameter.txt
if [ ! -f "$PARAM" ]; then
  PARAM=$(find /tmp -name "parameter.txt" -path "*sd-fuse*" 2>/dev/null | head -1)
fi
if [ -f "$PARAM" ]; then
  KERNEL_OFFSET=$(grep -oE '0x[0-9a-fA-F]+@0x[0-9a-fA-F]+\(kernel\)' "$PARAM" \
    | head -1 | sed -E 's/.*@(0x[0-9a-fA-F]+)\(kernel\)/\1/')
  KERNEL_OFFSET=$((KERNEL_OFFSET * 512))
else
  warn "未找到 parameter.txt，使用默认偏移 0x12000*512"
  KERNEL_OFFSET=$((0x12000 * 512))
fi
echo "kernel 分区偏移: $KERNEL_OFFSET bytes (0x$(printf %x $KERNEL_OFFSET))"
echo ""

read -r MAGIC CODE0 CODE1 KRNL_SIZE MAGIC_OFFSET KNL_ZERO_OK CODE1_TARGET < <(
  python3 - "$SELF_IMG" "$KERNEL_OFFSET" <<'PYEOF'
import sys, struct
img, off = sys.argv[1], int(sys.argv[2])
with open(img, 'rb') as f:
    f.seek(off); d = f.read(0x10010)

magic = d[0:4].hex()
code0 = d[8:12].hex()
code1 = int.from_bytes(d[12:16], 'little')
knl_size = int.from_bytes(d[4:8], 'little')
magic_off = d.find(b'ARM\x64')
zero_ok = "1" if d[0x48:0x10000] == b'\x00' * (0x10000 - 0x48) else "0"
imm26 = code1 & 0x03FFFFFF
if imm26 & 0x02000000:
    imm26 -= 0x04000000
target = 0x0C + imm26 * 4
print(magic, code0, f"{code1:08x}", knl_size, magic_off, zero_ok, target)
PYEOF
)

echo "── [1] 自建镜像 KRNL 头结构 ──"
echo "  magic:  $MAGIC"
echo "  code0:  $CODE0"
echo "  code1:  $CODE1  → 跳转目标 0x$(printf %x "$CODE1_TARGET")"
echo "  size:   $KRNL_SIZE bytes ($(python3 -c "print(f'{$KRNL_SIZE/1024/1024:.1f}')") MiB)"
echo "  magic@: $(printf '0x%x' "$MAGIC_OFFSET")"
echo "  零填充: $([ "$KNL_ZERO_OK" = "1" ] && echo '✅ 是' || echo '❌ 否')"

[ "$MAGIC" = "4b524e4c" ]      && ok "KRNL magic 正确"             || bad "KRNL magic 错误: $MAGIC"
[ "$CODE0" = "1f2003d5" ]      && ok "code0 = NOP (1f2003d5)"     || bad "code0 不是 NOP: $CODE0"

CODE1_OP=$(( (0x$CODE1 >> 26) & 0x3F ))
[ "$CODE1_OP" -eq 5 ] && ok "code1 opcode=5 (B 指令)" || bad "code1 opcode=$CODE1_OP (期望 5)"

[ "$MAGIC_OFFSET" = "64" ]     && ok "ARM64 magic 位于 0x40"       || bad "ARM64 magic 位置错误: $(printf '0x%x' "$MAGIC_OFFSET")"

[ "$KNL_ZERO_OK" = "1" ]       && ok "0x48..0x10000 零填充"        || bad "0x48..0x10000 非零填充"

if [ "$CODE1_TARGET" -ge $((0x10000)) ]; then
  ok "code1 目标 0x$(printf %x "$CODE1_TARGET") 在 payload 区"
else
  bad "code1 目标 0x$(printf %x "$CODE1_TARGET") 落在 header 区"
fi

echo ""
echo "── [2] 内核大小合理性 ──"
if [ "$KRNL_SIZE" -gt $((10 * 1024 * 1024)) ] && [ "$KRNL_SIZE" -lt $((200 * 1024 * 1024)) ]; then
  ok "内核大小在合理范围（10–200 MiB）"
else
  bad "内核大小异常: $KRNL_SIZE"
fi

echo ""
echo "── [3] 与官方固件对比 ──"

if [ -f "$OFFICIAL_DIR/.no_reference" ] || [ -z "$(find "$OFFICIAL_DIR" -maxdepth 1 -name '*.img' 2>/dev/null)" ]; then
  warn "无官方参考镜像，跳过对比"
else
  OFF_IMG=$(find "$OFFICIAL_DIR" -maxdepth 1 -name "*.img" | head -1)
  echo "  官方镜像: $OFF_IMG"

  read -r OFF_MAGIC OFF_CODE0 OFF_CODE1 OFF_MAGIC_POS OFF_CODE1_TARGET < <(
    python3 - "$OFF_IMG" "$KERNEL_OFFSET" <<'PYEOF'
import sys, struct
img, off = sys.argv[1], int(sys.argv[2])
with open(img, 'rb') as f:
    f.seek(off); d = f.read(256)
magic = d[0:4].hex()
code0 = d[8:12].hex()
code1 = int.from_bytes(d[12:16], 'little')
magic_off = d.find(b'ARM\x64')
imm26 = code1 & 0x03FFFFFF
if imm26 & 0x02000000: imm26 -= 0x04000000
target = 0x0C + imm26 * 4
print(magic, code0, f"{code1:08x}", magic_off, target)
PYEOF
  )

  echo "  官方 magic: $OFF_MAGIC  code0: $OFF_CODE0  code1: $OFF_CODE1  magic@: $(printf '0x%x' "$OFF_MAGIC_POS")"

  [ "$MAGIC" = "$OFF_MAGIC" ]  && ok "KRNL magic 与官方一致"                || bad "KRNL magic 不一致"
  [ "$CODE0" = "$OFF_CODE0" ]  && ok "code0 与官方完全一致"                || bad "code0 不一致"

  OFF_CODE1_OP=$(( (0x$OFF_CODE1 >> 26) & 0x3F ))
  [ "$CODE1_OP" = "$OFF_CODE1_OP" ] \
    && ok "code1 指令类型与官方一致（opcode=$CODE1_OP）" \
    || warn "code1 指令类型不同"

  [ "$MAGIC_OFFSET" = "$OFF_MAGIC_POS" ] \
    && ok "ARM64 magic 位置与官方一致（$(printf '0x%x' "$MAGIC_OFFSET")）" \
    || bad "ARM64 magic 位置不一致"

  echo ""
  echo "  ─ code1 精确值对比 ─"
  echo "    自建 code1 = 0x$CODE1   → 目标 0x$(printf %x "$CODE1_TARGET")"
  echo "    官方 code1 = 0x$OFF_CODE1 → 目标 0x$(printf %x "$OFF_CODE1_TARGET")"
  if [ "$CODE1" = "$OFF_CODE1" ]; then
    ok "code1 与官方完全一致"
  else
    warn "code1 精确值不同（内核版本不同，属预期）"
    if [ "$CODE1_TARGET" -ge $((0x10000)) ] && [ "$OFF_CODE1_TARGET" -ge $((0x10000)) ]; then
      ok "两者 code1 目标均落在 payload 区（>=0x10000）"
    else
      bad "code1 目标未落在 payload 区"
    fi
  fi
fi

echo ""
echo "════════════════════════════════════════════════════════"
echo "  验证结果: 通过 $PASS 项 / 失败 $FAIL 项"
echo "════════════════════════════════════════════════════════"

if [ "$FAIL" -gt 0 ]; then
  echo "❌ 验证失败，禁止上传"
  exit 1
fi
echo "✅ 所有关键项验证通过，允许上传"
exit 0