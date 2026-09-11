#!/bin/bash
# verify-against-official.sh - 修复字节序问题
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

PASS=0
FAIL=0
ok()   { echo "  ✅ $*"; PASS=$((PASS+1)); }
bad()  { echo "  ❌ $*"; FAIL=$((FAIL+1)); }
warn() { echo "  ⚠️  $*"; }

[ ! -f "$SELF_IMG" ] && { echo "❌ 自建镜像不存在: $SELF_IMG"; exit 2; }

SELF_SIZE=$(stat -c%s "$SELF_IMG")
echo "自建镜像大小: $SELF_SIZE bytes"
echo ""

KERNEL_OFFSET=$((0x12000 * 512))

# ============================================================
# 用 Python 一次性读取所有关键字段（正确处理小端序）
# ============================================================
read -r MAGIC CODE0 CODE1 KRNL_SIZE MAGIC_OFFSET < <(
  python3 - "$SELF_IMG" "$KERNEL_OFFSET" <<'PYEOF'
import sys
img, off = sys.argv[1], int(sys.argv[2])
with open(img, 'rb') as f:
    f.seek(off); d = f.read(256)

magic = d[0:4].hex()
code0 = d[8:12].hex()
code1 = d[12:16].hex()
size  = int.from_bytes(d[4:8], 'little')       # 关键：小端序
mpos  = d.find(b'ARM\x64')

print(magic, code0, code1, size, mpos if mpos >= 0 else -1)
PYEOF
)

echo "── [1] 自建镜像 KRNL 头结构 ──"
echo "  magic:  $MAGIC"
echo "  code0:  $CODE0"
echo "  code1:  $CODE1"
echo "  size:   $KRNL_SIZE bytes ($(python3 -c "print(f'{$KRNL_SIZE/1024/1024:.1f}')") MiB)"
echo "  magic@: $(printf '0x%x' "$MAGIC_OFFSET")"

if [ "$MAGIC" = "4b524e4c" ]; then ok "KRNL magic 正确"; else bad "KRNL magic 错误: $MAGIC"; fi
if [ "$CODE0" = "1f2003d5" ]; then ok "code0 = NOP (1f2003d5) 与官方一致"; else bad "code0 不是 NOP: $CODE0"; fi

CODE1_TOP=$(echo "$CODE1" | cut -c7-8)
if [ "$CODE1_TOP" = "14" ]; then ok "code1 是 B 指令 (top byte = 0x14)"; else warn "code1 非标准 B: top=0x$CODE1_TOP"; fi

if [ "$MAGIC_OFFSET" = "64" ]; then ok "ARM64 magic 位于 0x40"; else bad "ARM64 magic 位置错误: $(printf '0x%x' "$MAGIC_OFFSET")"; fi

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
  warn "无官方参考镜像，跳过对比（仅做结构验证）"
else
  OFF_IMG=$(find "$OFFICIAL_DIR" -maxdepth 1 -name "*.img" | head -1)
  echo "  官方镜像: $OFF_IMG"

  read -r OFF_MAGIC OFF_CODE0 OFF_CODE1 OFF_MAGIC_POS < <(
    python3 - "$OFF_IMG" "$KERNEL_OFFSET" <<'PYEOF'
import sys
img, off = sys.argv[1], int(sys.argv[2])
with open(img, 'rb') as f:
    f.seek(off); d = f.read(256)
print(d[0:4].hex(), d[8:12].hex(), d[12:16].hex(),
      d.find(b'ARM\x64') if d.find(b'ARM\x64') >= 0 else -1)
PYEOF
  )

  echo "  官方 magic: $OFF_MAGIC  code0: $OFF_CODE0  code1: $OFF_CODE1  magic@: $(printf '0x%x' "$OFF_MAGIC_POS")"

  [ "$MAGIC" = "$OFF_MAGIC" ]      && ok "KRNL magic 与官方一致"       || bad "KRNL magic 不一致（$MAGIC vs $OFF_MAGIC）"
  [ "$CODE0" = "$OFF_CODE0" ]      && ok "code0 与官方完全一致（$CODE0）" || bad "code0 不一致（$CODE0 vs $OFF_CODE0）"
  [ "$CODE1_TOP" = "$(echo "$OFF_CODE1" | cut -c7-8)" ] \
    && ok "code1 指令类型与官方一致（B）" \
    || warn "code1 指令类型不同（self=0x$CODE1_TOP off=0x$(echo "$OFF_CODE1" | cut -c7-8)）"
  [ "$MAGIC_OFFSET" = "$OFF_MAGIC_POS" ] \
    && ok "ARM64 magic 位置与官方一致（$(printf '0x%x' "$MAGIC_OFFSET")）" \
    || bad "ARM64 magic 位置不一致（self=$(printf '0x%x' "$MAGIC_OFFSET") off=$(printf '0x%x' "$OFF_MAGIC_POS")）"
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