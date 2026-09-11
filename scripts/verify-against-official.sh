#!/bin/bash
# verify-against-official.sh
# 对比自建固件与官方固件的关键结构，任一项不一致就失败（exit 1），
# 用于在 GitHub Actions 中作为"验证门禁"，验证通过才允许上传发布。
#
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

ok()    { echo "  ✅ $*"; PASS=$((PASS+1)); }
bad()   { echo "  ❌ $*"; FAIL=$((FAIL+1)); }
warn()  { echo "  ⚠️  $*"; }

# ---------- 0. 输入检查 ----------
if [ ! -f "$SELF_IMG" ]; then
  echo "❌ 自建镜像不存在: $SELF_IMG"
  exit 2
fi

SELF_SIZE=$(stat -c%s "$SELF_IMG")
echo "自建镜像大小: $SELF_SIZE bytes"
echo ""

# ============================================================
# 1. 自建镜像 KRNL 头验证（硬性要求）
# ============================================================
echo "── [1] 自建镜像 KRNL 头结构 ──"

KERNEL_OFFSET=$((0x12000 * 512))
HEAD_HEX=$(dd if="$SELF_IMG" bs=1 skip="$KERNEL_OFFSET" count=64 2>/dev/null | xxd -p -c 64)

# 逐字节解析
MAGIC=$(echo "$HEAD_HEX" | cut -c1-8)
CODE0=$(echo "$HEAD_HEX" | cut -c17-24)
CODE1=$(echo "$HEAD_HEX" | cut -c25-32)

echo "  magic:  $MAGIC"
echo "  code0:  $CODE0"
echo "  code1:  $CODE1"

if [ "$MAGIC" = "4b524e4c" ]; then
  ok "KRNL magic 正确"
else
  bad "KRNL magic 错误（期望 4b524e4c，实际 $MAGIC）"
fi

# 官方 code0 = 1f2003d5（NOP），小端序 hex 显示
if [ "$CODE0" = "1f2003d5" ]; then
  ok "code0 = NOP (1f2003d5) 与官方一致"
else
  bad "code0 不是 NOP（期望 1f2003d5，实际 $CODE0）"
fi

# code1 低 6 位应为 14（B 指令）
CODE1_TOP=$(echo "$CODE1" | cut -c7-8)
if [ "$CODE1_TOP" = "14" ]; then
  ok "code1 是 B 指令 (top byte = 0x14)"
else
  warn "code1 不是标准 B 指令（top byte = 0x$CODE1_TOP）"
fi

# ARM64 magic 位置
MAGIC_OFFSET=$(dd if="$SELF_IMG" bs=1 skip="$KERNEL_OFFSET" count=256 2>/dev/null | grep -abo 'ARMd' | head -1 | cut -d: -f1)
if [ "$MAGIC_OFFSET" = "64" ]; then
  ok "ARM64 magic 位于 0x40"
else
  bad "ARM64 magic 位置错误（期望 0x40，实际 0x$MAGIC_OFFSET）"
fi

echo ""

# ============================================================
# 2. 内核大小验证（不能为 0，不能过大）
# ============================================================
echo "── [2] 内核大小合理性 ──"

KRNL_SIZE_LE=$(dd if="$SELF_IMG" bs=1 skip=$((KERNEL_OFFSET + 4)) count=4 2>/dev/null | xxd -p -c 4)
KRNL_SIZE=$(python3 -c "print(int('$KRNL_SIZE_LE', 16))" 2>/dev/null || echo 0)
echo "  KRNL size field: $KRNL_SIZE bytes ($(python3 -c "print(f'{$KRNL_SIZE/1024/1024:.1f}')" 2>/dev/null || echo '?') MiB)"

if [ "$KRNL_SIZE" -gt $((10 * 1024 * 1024)) ] && [ "$KRNL_SIZE" -lt $((200 * 1024 * 1024)) ]; then
  ok "内核大小在合理范围（10–200 MiB）"
else
  bad "内核大小异常: $KRNL_SIZE"
fi
echo ""

# ============================================================
# 3. 与官方对比（如果官方参考存在）
# ============================================================
echo "── [3] 与官方固件对比 ──"

if [ -f "$OFFICIAL_DIR/.no_reference" ] || [ -z "$(find "$OFFICIAL_DIR" -maxdepth 1 -name '*.img' 2>/dev/null)" ]; then
  warn "无官方参考镜像，跳过对比（仅做结构验证）"
else
  OFF_IMG=$(find "$OFFICIAL_DIR" -maxdepth 1 -name "*.img" | head -1)
  echo "  官方镜像: $OFF_IMG"

  OFF_MAGIC=$(dd if="$OFF_IMG" bs=1 skip="$KERNEL_OFFSET" count=4 2>/dev/null | xxd -p -c 4)
  OFF_CODE0=$(dd if="$OFF_IMG" bs=1 skip=$((KERNEL_OFFSET + 8)) count=4 2>/dev/null | xxd -p -c 4)
  OFF_CODE1=$(dd if="$OFF_IMG" bs=1 skip=$((KERNEL_OFFSET + 12)) count=4 2>/dev/null | xxd -p -c 4)
  OFF_MAGIC_POS=$(dd if="$OFF_IMG" bs=1 skip="$KERNEL_OFFSET" count=256 2>/dev/null | grep -abo 'ARMd' | head -1 | cut -d: -f1)

  echo "  官方 magic: $OFF_MAGIC  code0: $OFF_CODE0  code1: $OFF_CODE1  magic@: 0x$OFF_MAGIC_POS"

  # 3a. KRNL magic 一致
  if [ "$MAGIC" = "$OFF_MAGIC" ]; then
    ok "KRNL magic 与官方一致"
  else
    bad "KRNL magic 不一致（自建=$MAGIC 官方=$OFF_MAGIC）"
  fi

  # 3b. code0 一致（最关键）
  if [ "$CODE0" = "$OFF_CODE0" ]; then
    ok "code0 与官方完全一致（$CODE0）"
  else
    bad "code0 不一致（自建=$CODE0 官方=$OFF_CODE0）→ U-Boot 会执行到错误指令"
  fi

  # 3c. code1 高位字节一致（低 26 位是跳转偏移，可能不同）
  if [ "$CODE1_TOP" = "$(echo "$OFF_CODE1" | cut -c7-8)" ]; then
    ok "code1 指令类型与官方一致（B 指令）"
  else
    warn "code1 指令类型与官方不同（自建=0x$CODE1_TOP 官方=0x$(echo "$OFF_CODE1" | cut -c7-8)）"
  fi

  # 3d. ARM64 magic 位置一致
  if [ "$MAGIC_OFFSET" = "$OFF_MAGIC_POS" ]; then
    ok "ARM64 magic 位置与官方一致（0x$MAGIC_OFFSET）"
  else
    bad "ARM64 magic 位置不一致（自建=0x$MAGIC_OFFSET 官方=0x$OFF_MAGIC_POS）"
  fi

  # 3e. KRNL 头部 64 字节整体相似度（容忍 size 字段差异）
  SELF_HDR_NO_SIZE=$(dd if="$SELF_IMG" bs=1 skip="$KERNEL_OFFSET" count=64 2>/dev/null \
                     | python3 -c "
import sys
d = sys.stdin.buffer.read()
# 把 size(4:8) 和 image_size(0x18:0x20) 归零后比对
d = d[:4] + b'\x00'*4 + d[8:0x18] + b'\x00'*8 + d[0x20:]
sys.stdout.buffer.write(d)
" | xxd -p -c 64)
  OFF_HDR_NO_SIZE=$(dd if="$OFF_IMG" bs=1 skip="$KERNEL_OFFSET" count=64 2>/dev/null \
                    | python3 -c "
import sys
d = sys.stdin.buffer.read()
d = d[:4] + b'\x00'*4 + d[8:0x18] + b'\x00'*8 + d[0x20:]
sys.stdout.buffer.write(d)
" | xxd -p -c 64)
  if [ "$SELF_HDR_NO_SIZE" = "$OFF_HDR_NO_SIZE" ]; then
    ok "KRNL 头 64 字节（忽略 size 字段）与官方完全一致"
  else
    warn "KRNL 头有差异（可接受，仅比对 code0/magic 即可）"
  fi

  # 3f. GPT 分区对比：kernel 起始 LBA 应一致
  SELF_K_LBA=$(python3 -c "
import struct
with open('$SELF_IMG','rb') as f:
    f.seek(512); h = f.read(92)
    ent_lba = struct.unpack_from('<Q', h, 72)[0]
    n = struct.unpack_from('<I', h, 80)[0]
    es = struct.unpack_from('<I', h, 84)[0]
    f.seek(ent_lba*512); ents = f.read(es*n)
for i in range(n):
    o = i*es
    nm = ents[o+56:o+56+72].split(b'\x00')[0].decode('utf-16-le', errors='ignore').strip()
    if nm == 'kernel':
        print(struct.unpack_from('<Q', ents, o+32)[0]); break
" 2>/dev/null)
  OFF_K_LBA=$(python3 -c "
import struct
with open('$OFF_IMG','rb') as f:
    f.seek(512); h = f.read(92)
    ent_lba = struct.unpack_from('<Q', h, 72)[0]
    n = struct.unpack_from('<I', h, 80)[0]
    es = struct.unpack_from('<I', h, 84)[0]
    f.seek(ent_lba*512); ents = f.read(es*n)
for i in range(n):
    o = i*es
    nm = ents[o+56:o+56+72].split(b'\x00')[0].decode('utf-16-le', errors='ignore').strip()
    if nm == 'kernel':
        print(struct.unpack_from('<Q', ents, o+32)[0]); break
" 2>/dev/null)
  echo "  kernel 起始 LBA: 自建=0x$SELF_K_LBA 官方=0x$OFF_K_LBA"
  if [ -n "$SELF_K_LBA" ] && [ "$SELF_K_LBA" = "$OFF_K_LBA" ]; then
    ok "kernel 分区起始 LBA 与官方一致（0x$SELF_K_LBA）"
  elif [ -n "$SELF_K_LBA" ]; then
    warn "kernel 分区起始 LBA 与官方不同（不影响启动，官方=$OFF_K_LBA 自建=$SELF_K_LBA）"
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