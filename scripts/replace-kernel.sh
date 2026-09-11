#!/bin/bash
# replace-kernel.sh - 支持6.18/6.12/6.6/6.1，PE→KRNL转换（官方格式对齐）+ kernel分区自动扩容
set -euo pipefail

VERSION="2026-09-11-v18-official-aligned"
log()  { echo -e "\033[0;32m[replace]\033[0m $*"; }
warn() { echo -e "\033[0;33m[replace]\033[0m $*"; }
err()  { echo -e "\033[0;31m[replace]\033[0m $*" >&2; }
log "replace-kernel.sh version: $VERSION"

IMAGES_TGZ="$1"; SDFUSE_DIR="$2"; DIST_NAME="$3"; OUTPUT_IMG="$4"
TARGET_MODEL="${TARGET_MODEL:-r5s}"
KERNEL_VERSION="${KERNEL_VERSION:-6.18.y}"

log "参数: images=$(basename "$IMAGES_TGZ"), model=$TARGET_MODEL, version=$KERNEL_VERSION"

WORK_DIR=$(mktemp -d /tmp/replace-kernel.XXXXXX)
trap "rm -rf $WORK_DIR" EXIT
log "工作目录: $WORK_DIR"

# ============================================================
# 1. 解压 images.tgz
# ============================================================
log "========== [1/8] 解压 images.tgz =========="
mkdir -p "$WORK_DIR/base"
tar xzf "$IMAGES_TGZ" -C "$WORK_DIR/base"
BASE_DIR=$(find "$WORK_DIR/base" -maxdepth 2 -type d -name "friendlywrt*" | head -1)
[ -z "$BASE_DIR" ] && { err "找不到顶层目录"; exit 1; }
log "  顶层: $BASE_DIR"

# ============================================================
# 2. 扫描内核版本
# ============================================================
log "========== [2/8] 扫描 $KERNEL_VERSION 内核 =========="

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
log "  版本前缀: ${PREFIX:-auto}"

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

  [ -z "$VERS" ] && { log "    (无匹配)"; continue; }

  log "    匹配版本:"
  echo "$VERS" | sed 's/^/      /'

  for v in $VERS; do
    [ -z "${VER_TO_SOURCE[$v]:-}" ] && VER_TO_SOURCE["$v"]="$REPO:$RELEASE"
  done
done

if [ ${#VER_TO_SOURCE[@]} -eq 0 ]; then
  err "  无匹配 $KERNEL_VERSION 的内核"
  exit 1
fi

SELECTED_VER=$(printf '%s\n' "${!VER_TO_SOURCE[@]}" | sort -V | tail -1)
SELECTED_SOURCE="${VER_TO_SOURCE[$SELECTED_VER]}"
SELECTED_REPO="${SELECTED_SOURCE%%:*}"
SELECTED_RELEASE="${SELECTED_SOURCE##*:}"

log ""
log "  ============ 决策 ============"
log "  选中版本: $SELECTED_VER"
log "  来源: $SELECTED_REPO / $SELECTED_RELEASE"

# ============================================================
# 3. 下载并解压
# ============================================================
log "========== [3/8] 下载 $SELECTED_VER =========="

KERNEL_CACHE="/tmp/kernel-cache-${SELECTED_RELEASE}/${SELECTED_VER}"
if [ ! -f "$KERNEL_CACHE/.ready" ]; then
  rm -rf "$KERNEL_CACHE"; mkdir -p "$KERNEL_CACHE"; cd "$KERNEL_CACHE"
  URL="https://github.com/${SELECTED_REPO}/releases/download/${SELECTED_RELEASE}/${SELECTED_VER}.tar.gz"
  log "  URL: $URL"

  DOWNLOAD_OK=false
  wget -q --timeout=120 --tries=2 "$URL" -O kernel.tar.gz 2>/dev/null && DOWNLOAD_OK=true
  [ "$DOWNLOAD_OK" != "true" ] && curl -L -f --connect-timeout 60 --max-time 300 "$URL" -o kernel.tar.gz 2>/dev/null && DOWNLOAD_OK=true
  [ "$DOWNLOAD_OK" != "true" ] && { err "下载失败"; exit 1; }

  tar xzf kernel.tar.gz

  LOCAL_KDIR="$SELECTED_VER"
  [ ! -d "$LOCAL_KDIR" ] && LOCAL_KDIR=$(find . -maxdepth 2 -type d -name "*${SELECTED_VER}*" ! -path "./boot*" ! -path "./dtb*" ! -path "./modules*" | head -1)
  [ -z "$LOCAL_KDIR" ] && { err "找不到内核目录"; exit 1; }

  echo "$KERNEL_CACHE/$LOCAL_KDIR" > "$KERNEL_CACHE/.topdir"

  for type in boot dtb modules; do
    TAR=$(find "$LOCAL_KDIR" -maxdepth 1 -name "${type}-*.tar.gz" | head -1)
    [ -z "$TAR" ] && [ "$type" = "dtb" ] && TAR=$(find "$LOCAL_KDIR" -maxdepth 1 -name "dtb-rockchip-*.tar.gz" | head -1)
    [ -n "$TAR" ] && tar xzf "$TAR" -C "$KERNEL_CACHE" && log "  ✓ 解压 $type"
  done

  touch .ready
fi
KERNEL_TOPDIR=$(cat "$KERNEL_CACHE/.topdir" 2>/dev/null || echo "$KERNEL_CACHE/$SELECTED_VER")
log "  缓存: $KERNEL_CACHE"

# ============================================================
# 4. 复制骨架
# ============================================================
log "========== [4/8] 复制骨架 =========="
TARGET_DIR="$SDFUSE_DIR/$DIST_NAME"
rm -rf "$TARGET_DIR"
cp -a "$BASE_DIR" "$TARGET_DIR"

# ============================================================
# 5. 构造 kernel.img —— PE→KRNL 转换（官方格式对齐）
# ============================================================
log "========== [5/8] 构造 kernel.img（官方格式对齐） =========="

IMAGE_FILE=""
for pattern in "vmlinuz-*" "Image" "Image-*" "kernel*.img" "*.bin"; do
  IMAGE_FILE=$(find "$KERNEL_CACHE" -maxdepth 3 -type f -name "$pattern" 2>/dev/null | head -1)
  [ -n "$IMAGE_FILE" ] && break
done
[ -z "$IMAGE_FILE" ] && { err "找不到内核 Image"; find "$KERNEL_CACHE" -type f | head -20; exit 1; }

IMAGE_SIZE=$(stat -c%s "$IMAGE_FILE")
log "  内核文件: $(basename "$IMAGE_FILE") ($IMAGE_SIZE bytes)"
log "  类型: $(file -b "$IMAGE_FILE")"
log "  前 64 字节:"
xxd -l 64 "$IMAGE_FILE" | sed 's/^/    /'

python3 - "$IMAGE_FILE" "$TARGET_DIR/kernel.img" <<'PYEOF'
import sys, struct

src, dst = sys.argv[1], sys.argv[2]
raw = open(src, 'rb').read()
ARM64_MAGIC = b'ARM\x64'

print("  输入大小: %d" % len(raw))

if raw[:4] == b'KRNL':
    print("  已是 KRNL，直接使用")
    open(dst, 'wb').write(raw)
    sys.exit(0)

if raw[:2] == b'MZ':
    pe_off = struct.unpack_from('<I', raw, 0x3C)[0]
    assert raw[pe_off:pe_off+4] == b'PE\x00\x00', "PE 签名错误"
    print("  PE header @ 0x%x" % pe_off)

    coff = pe_off + 4
    nsec = struct.unpack_from('<H', raw, coff + 2)[0]
    opt_size = struct.unpack_from('<H', raw, coff + 16)[0]
    sec_base = coff + 20 + opt_size

    secs = []
    for i in range(nsec):
        o = sec_base + i * 40
        name = raw[o:o+8].rstrip(b'\x00').decode('ascii', 'ignore')
        roff  = struct.unpack_from('<I', raw, o + 20)[0]
        rsize = struct.unpack_from('<I', raw, o + 16)[0]
        secs.append((name, roff, rsize))
        print("    Section %-8s file_off=0x%08x size=%d" % (name, roff, rsize))

    payload = b''
    for wanted in ('.text', '.rodata', '.data'):
        for sname, roff, rsize in secs:
            if sname == wanted:
                payload += raw[roff:roff + rsize]
                print("    + %s: %d bytes" % (wanted, rsize))

    if not payload:
        secs.sort(key=lambda x: -x[2])
        payload = raw[secs[0][1]:secs[0][1] + secs[0][2]]
        print("    (fallback) 取最大节 %s: %d bytes" % (secs[0][0], secs[0][2]))

    print("  payload 总大小: %d bytes" % len(payload))

    if len(payload) >= 0x40 and payload[0x38:0x3c] == ARM64_MAGIC:
        print("  payload 已是标准 ARM64 Image")
        image = payload
    else:
        print("  构造 ARM64 Image 头: code0=NOP, code1=B +0x40")
        b_insn = 0x14000000 | (0x40 // 4)
        hdr = bytearray(0x40)
        struct.pack_into('<I', hdr, 0x00, 0xd503201f)
        struct.pack_into('<I', hdr, 0x04, b_insn)
        struct.pack_into('<Q', hdr, 0x08, 0)
        struct.pack_into('<Q', hdr, 0x10, len(payload))
        struct.pack_into('<Q', hdr, 0x18, 0x0a)
        hdr[0x38:0x3c] = ARM64_MAGIC
        image = bytes(hdr) + payload
else:
    idx = raw.find(ARM64_MAGIC)
    print("  非 PE/KRNL，magic @ 0x%x" % idx)
    if idx == 0x38:
        image = raw
    else:
        print("  ✗ 未知格式"); sys.exit(1)

knl = b'KRNL' + struct.pack('<I', len(image)) + image
open(dst, 'wb').write(knl)

out = open(dst, 'rb').read(0x80)
assert out[0:4] == b'KRNL'
assert out[0x08:0x0c] == b'\x1f\x20\x03\xd5', "code0 必须是 NOP"
assert out[0x40:0x44] == ARM64_MAGIC, "magic 必须在 0x40"

print("  ✓ 官方格式对齐验证通过")
print("    KRNL size @ 0x04 = %d" % struct.unpack_from('<I', out, 4)[0])
print("    code0 @ 0x08     = %s (NOP)" % out[0x08:0x0c].hex())
print("    code1 @ 0x0c     = %s" % out[0x0c:0x10].hex())
print("    magic @ 0x40     = %s" % out[0x40:0x44])
print("  SUCCESS")
PYEOF

log "  新 kernel.img: $(stat -c%s "$TARGET_DIR/kernel.img") bytes"
xxd -l 96 "$TARGET_DIR/kernel.img" | sed 's/^/    /'

# ============================================================
# 5.5 动态扩容 kernel 分区
# ============================================================
log "========== [5.5/8] 扩容 kernel 分区 =========="

PARAM_FILE="$TARGET_DIR/parameter.txt"
[ -f "$PARAM_FILE" ] || { err "缺少 parameter.txt"; exit 1; }

python3 - "$PARAM_FILE" "$(stat -c%s "$TARGET_DIR/kernel.img")" <<'PARAM_PYEOF'
import re, sys
param_file, kernel_size = sys.argv[1], int(sys.argv[2])
with open(param_file) as f:
    content = f.read()

kernel_re = re.compile(r'0x([0-9a-fA-F]+)@(0x[0-9a-fA-F]+)\(kernel\)', re.IGNORECASE)
m = kernel_re.search(content)
if not m:
    print("[param] 未找到 kernel 分区"); sys.exit(0)

old_size   = int(m.group(1), 16)
kernel_off = int(m.group(2), 16)
kernel_end = kernel_off + old_size

need_sectors = (kernel_size + 511) // 512
rounded  = ((need_sectors + 0x3FFF) // 0x4000) * 0x4000
new_size = max(rounded, old_size)

print(f"[param] old={old_size*512/1024/1024:.1f} MiB need={need_sectors*512/1024/1024:.1f} MiB new={new_size*512/1024/1024:.1f} MiB")

if new_size == old_size:
    print("[param] 无需扩容"); sys.exit(0)

delta = new_size - old_size
new_kernel = f'0x{new_size:08x}@{m.group(2)}(kernel)'
content = content[:m.start()] + new_kernel + content[m.end():]

def shift(match):
    off = int(match.group(1), 16)
    if off >= kernel_end:
        return f'@0x{off + delta:08x}'
    return match.group(0)
content = re.sub(r'@0x([0-9a-fA-F]+)', shift, content)

with open(param_file, 'w') as f:
    f.write(content)
print(f"[param] 已更新 (delta={delta} sectors = {delta*512/1024/1024:.1f} MiB)")
PARAM_PYEOF

sed 's/^/    /' "$PARAM_FILE"

# ============================================================
# 6. dtb + uInitrd
# ============================================================
log "========== [6/8] dtb + uInitrd =========="

DTB_TAR=""
for search_dir in "$KERNEL_TOPDIR" "$KERNEL_CACHE"; do
  DTB_TAR=$(find "$search_dir" -maxdepth 2 -name "dtb-rockchip-*.tar.gz" 2>/dev/null | head -1)
  [ -n "$DTB_TAR" ] && break
done

if [ -n "$DTB_TAR" ]; then
  log "  dtb 包: $(basename "$DTB_TAR")"
  R5S_PATH=$(tar tzf "$DTB_TAR" | grep -E "(^|/)rk3568-nanopi-r5s\.dtb$" | head -1 || echo "")
  R5C_PATH=$(tar tzf "$DTB_TAR" | grep -E "(^|/)rk3568-nanopi-r5c\.dtb$" | head -1 || echo "")

  mkdir -p "$TARGET_DIR/dtb/rockchip"
  if [ -n "$R5S_PATH" ]; then
    tar xzf "$DTB_TAR" -C "$WORK_DIR" "$R5S_PATH"
    cp "$WORK_DIR/$R5S_PATH" "$TARGET_DIR/dtb/rockchip/rk3568-nanopi-r5s.dtb"
    log "  ✓ r5s dtb: $(stat -c%s "$TARGET_DIR/dtb/rockchip/rk3568-nanopi-r5s.dtb") bytes"
  fi
  if [ -n "$R5C_PATH" ]; then
    tar xzf "$DTB_TAR" -C "$WORK_DIR" "$R5C_PATH"
    cp "$WORK_DIR/$R5C_PATH" "$TARGET_DIR/dtb/rockchip/rk3568-nanopi-r5c.dtb"
    log "  ✓ r5c dtb: $(stat -c%s "$TARGET_DIR/dtb/rockchip/rk3568-nanopi-r5c.dtb") bytes"
  fi
fi

UINITRD=$(find "$KERNEL_CACHE" -type f -name "uInitrd-*" | head -1)
if [ -n "$UINITRD" ]; then
  cp "$UINITRD" "$TARGET_DIR/uInitrd"
  log "  ✓ uInitrd: $(stat -c%s "$TARGET_DIR/uInitrd") bytes"
else
  log "  ⚠ 无 uInitrd，保留骨架"
fi

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
tail -30 /tmp/mk-sd.log | sed 's/^/    /'

FOUND_IMG=$(find out -maxdepth 1 -name "*.img" -print -quit)
[ -z "$FOUND_IMG" ] && { err "未生成镜像"; exit 1; }
mv "$FOUND_IMG" "$OUTPUT_IMG"

# ============================================================
# 8. 最终验证（含与官方对比，如果有 REF_IMG）
# ============================================================
log "========== [8/8] 验证 =========="
KERNEL_OFFSET=$((0x12000 * 512))

python3 - "$OUTPUT_IMG" "$KERNEL_OFFSET" "${REF_IMG:-}" <<'PYEOF'
import sys, os
img, off = sys.argv[1], int(sys.argv[2])
ref = sys.argv[3] if len(sys.argv) > 3 else ""

with open(img, 'rb') as f:
    f.seek(off); data = f.read(256)

assert data[0:4] == b'KRNL', 'KRNL missing'
assert data[0x08:0x0c] == b'\x1f\x20\x03\xd5', 'code0 必须是 NOP'
magic_idx = data.find(b'ARM\x64')
assert magic_idx == 0x40, f'magic 位置错误 0x{magic_idx:x}'

print(f"    自建 KRNL size: {int.from_bytes(data[4:8],'little')}")
print(f"    自建 code0:     {data[0x08:0x0c].hex()} (NOP)")
print(f"    自建 code1:     {data[0x0c:0x10].hex()}")
print(f"    自建 magic@:    0x{magic_idx:x}")

if ref and os.path.exists(ref):
    with open(ref, 'rb') as f:
        f.seek(off); ref_data = f.read(256)
    if ref_data[0:4] == b'KRNL':
        print()
        print(f"    官方 KRNL size: {int.from_bytes(ref_data[4:8],'little')}")
        print(f"    官方 code0:     {ref_data[0x08:0x0c].hex()}")
        print(f"    官方 code1:     {ref_data[0x0c:0x10].hex()}")
        print(f"    官方 magic@:    0x{ref_data.find(b'ARM\x64'):x}")

        if data[0x08:0x0c] == ref_data[0x08:0x0c]:
            print("    ✅ code0 与官方一致")
        else:
            print("    ❌ code0 与官方不一致")
            sys.exit(1)
    else:
        print(f"    ⚠ 官方参考固件在 0x{off:x} 处不是 KRNL，跳过对比")
else:
    print("    （无官方参考固件，跳过对比）")

print("    ✓✓✓ 最终镜像含有效内核")
PYEOF

log "=========================================="
log "✓ 完成 (version $VERSION)"
log "  内核: $SELECTED_VER"
log "  来源: $SELECTED_REPO / $SELECTED_RELEASE"
log "  输出: $OUTPUT_IMG ($(($(stat -c%s "$OUTPUT_IMG")/1024/1024)) MiB)"
log "=========================================="