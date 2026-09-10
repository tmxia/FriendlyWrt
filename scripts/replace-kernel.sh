#!/bin/bash
# replace-kernel.sh - 从 breakingbadboy/OpenWrt 下载内核并修复 EFI stub 头
set -euo pipefail

VERSION="2026-09-11-v8-pefix"
log() { echo -e "\033[0;32m[replace]\033[0m $*"; }
warn() { echo -e "\033[0;33m[replace]\033[0m $*"; }
err() { echo -e "\033[0;31m[replace]\033[0m $*" >&2; }
log "replace-kernel.sh version: $VERSION"

IMAGES_TGZ="$1"
SDFUSE_DIR="$2"
DIST_NAME="$3"
OUTPUT_IMG="$4"
TARGET_MODEL="${TARGET_MODEL:-r5s}"
SLIM_MODE="${SLIM_MODE:-true}"
KERNEL_REPO="${KERNEL_REPO:-breakingbadboy/OpenWrt}"
KERNEL_VERSION="${KERNEL_VERSION:-6.12.y}"

log "参数: repo=$KERNEL_REPO, version=$KERNEL_VERSION, model=$TARGET_MODEL"

WORK_DIR=$(mktemp -d /tmp/replace-kernel.XXXXXX)
trap "rm -rf $WORK_DIR" EXIT
log "工作目录: $WORK_DIR"

# ============================================================
# 1. 解压官方 images tgz
# ============================================================
log "========== [1/6] 解压 images.tgz =========="
mkdir -p "$WORK_DIR/base"
tar xzf "$IMAGES_TGZ" -C "$WORK_DIR/base"
BASE_DIR=$(find "$WORK_DIR/base" -maxdepth 2 -type d -name "friendlywrt*" | head -1)
[ -z "$BASE_DIR" ] && { err "找不到顶层目录"; exit 1; }
log "  顶层: $BASE_DIR"

# ============================================================
# 2. 下载内核
# ============================================================
log "========== [2/6] 下载 $KERNEL_VERSION 内核 =========="

TAG_LIST=$(gh release list --limit 100 --repo "$KERNEL_REPO" --json tagName --jq '.[].tagName' 2>/dev/null || echo "")
[ -z "$TAG_LIST" ] && { err "无法列出 tag"; exit 1; }

# 优先 kernel_stable > kernel_rk35xx > kernel_rk3588 > 其他 kernel_*
KERNEL_TAG=""
for t in kernel_stable kernel_rk35xx kernel_rk3588 kernel_flippy; do
  echo "$TAG_LIST" | grep -qx "$t" && { KERNEL_TAG="$t"; break; }
done
[ -z "$KERNEL_TAG" ] && KERNEL_TAG=$(echo "$TAG_LIST" | grep -E '^kernel_' | head -1)
[ -z "$KERNEL_TAG" ] && { err "找不到 kernel_* tag"; exit 1; }
log "  选中 tag: $KERNEL_TAG"

ASSETS=$(gh release view "$KERNEL_TAG" --repo "$KERNEL_REPO" --json assets --jq '.assets[].name' 2>/dev/null || echo "")
[ -z "$ASSETS" ] && { err "无法获取 assets"; exit 1; }

VERSION_PREFIX="${KERNEL_VERSION%.y}"
MATCHED_VER=$(echo "$ASSETS" | grep -E "^${VERSION_PREFIX}\.[0-9]+\.tar\.gz$" | sed 's/\.tar\.gz//' | sort -V | tail -1)
[ -z "$MATCHED_VER" ] && {
  err "  找不到 $KERNEL_VERSION 匹配版本"
  err "  可用:"
  echo "$ASSETS" | grep -E '^[0-9]+\.[0-9]+' | head -20 | sed 's/^/    /'
  exit 1
}
log "  匹配版本: $MATCHED_VER"

KERNEL_CACHE="/tmp/kernel-cache-${KERNEL_TAG}/${MATCHED_VER}"
if [ ! -f "$KERNEL_CACHE/.ready" ]; then
  log "  下载 $MATCHED_VER..."
  rm -rf "$KERNEL_CACHE"
  mkdir -p "$KERNEL_CACHE"
  cd "$KERNEL_CACHE"
  URL="https://github.com/${KERNEL_REPO}/releases/download/${KERNEL_TAG}/${MATCHED_VER}.tar.gz"
  log "  URL: $URL"

  DOWNLOAD_OK=false
  wget -q --timeout=120 --tries=2 "$URL" -O kernel.tar.gz 2>/dev/null && DOWNLOAD_OK=true
  [ "$DOWNLOAD_OK" != "true" ] && curl -L -f --connect-timeout 60 --max-time 300 "$URL" -o kernel.tar.gz 2>/dev/null && DOWNLOAD_OK=true
  [ "$DOWNLOAD_OK" != "true" ] && { err "下载失败"; exit 1; }

  tar xzf kernel.tar.gz || { err "解压失败"; exit 1; }

  LOCAL_KDIR="$MATCHED_VER"
  [ ! -d "$LOCAL_KDIR" ] && LOCAL_KDIR=$(find . -maxdepth 2 -type d -name "*${MATCHED_VER}*" ! -path "./boot*" ! -path "./dtb*" ! -path "./modules*" | head -1)
  [ -z "$LOCAL_KDIR" ] && { err "找不到内核目录"; exit 1; }

  mkdir -p boot dtb modules
  for type in boot dtb modules; do
    TAR=$(find "$LOCAL_KDIR" -maxdepth 1 -name "${type}-*.tar.gz" | head -1)
    [ -z "$TAR" ] && [ "$type" = "dtb" ] && TAR=$(find "$LOCAL_KDIR" -maxdepth 1 -name "dtb-rockchip-*.tar.gz" | head -1)
    [ -n "$TAR" ] && tar xzf "$TAR" -C "$type" && log "  ✓ 解压 $type"
  done

  touch .ready
fi
log "  缓存: $KERNEL_CACHE"

# ============================================================
# 3. 复制骨架
# ============================================================
log "========== [3/6] 复制骨架 =========="
TARGET_DIR="$SDFUSE_DIR/$DIST_NAME"
rm -rf "$TARGET_DIR"
cp -a "$BASE_DIR" "$TARGET_DIR"

# ============================================================
# 4. 构造 kernel.img（修复 EFI stub 头）
# ============================================================
log "========== [4/6] 构造 kernel.img =========="

IMAGE_FILE=""
for pattern in "Image" "vmlinuz-*" "kernel*.img" "*.bin" "Image-*"; do
  IMAGE_FILE=$(find "$KERNEL_CACHE/boot" -maxdepth 3 -name "$pattern" -type f 2>/dev/null | head -1)
  [ -n "$IMAGE_FILE" ] && break
done
[ -z "$IMAGE_FILE" ] && { err "找不到内核 Image"; ls -la "$KERNEL_CACHE/boot/"; exit 1; }

IMAGE_SIZE=$(stat -c%s "$IMAGE_FILE")
log "  内核文件: $(basename "$IMAGE_FILE") ($IMAGE_SIZE bytes)"
log "  类型: $(file -b "$IMAGE_FILE")"
log "  前 64 字节:"
xxd -l 64 "$IMAGE_FILE" | sed 's/^/    /'

MAGIC=$(xxd -l 4 -p "$IMAGE_FILE")
log "  magic: $MAGIC"

# ============ 关键修复：处理 EFI stub / PE 格式 ============
if [ "$MAGIC" = "4b524e4c" ]; then
  # 已是 KRNL
  log "  >>> KRNL 格式，直接使用"
  cp "$IMAGE_FILE" "$TARGET_DIR/kernel.img"

elif [ "$MAGIC" = "d00dfeed" ]; then
  # FIT 格式
  log "  >>> FIT 格式，直接使用"
  cp "$IMAGE_FILE" "$TARGET_DIR/kernel.img"

elif [ "$(xxd -l 2 -p "$IMAGE_FILE")" = "4d5a" ]; then
  # PE/EFI stub —— 关键修复
  log "  >>> PE/EFI stub 格式，修复 ARM64 Image 头..."
  python3 - "$IMAGE_FILE" "$WORK_DIR/patched.img" <<'PYEOF'
import sys, struct

data = bytearray(open(sys.argv[1], 'rb').read())
file_size = len(data)

# 分析原始 header
orig_code0 = struct.unpack_from('<I', data, 0x00)[0]
orig_code1 = struct.unpack_from('<I', data, 0x04)[0]
orig_text_off = struct.unpack_from('<Q', data, 0x08)[0]
orig_img_size = struct.unpack_from('<Q', data, 0x10)[0]
orig_flags = struct.unpack_from('<Q', data, 0x18)[0]
magic_pos = data.find(b'ARM\x64')

print(f"    原 code0:       0x{orig_code0:08x}")
print(f"    原 code1:       0x{orig_code1:08x}")
print(f"    原 text_offset: 0x{orig_text_off:x} ({orig_text_off})")
print(f"    原 image_size:  0x{orig_img_size:x} ({orig_img_size} bytes)")
print(f"    原 flags:       0x{orig_flags:x}")
print(f"    ARM64 magic@:   0x{magic_pos:x}")
print(f"    实际文件大小:   {file_size} bytes")
print("")

# 修复 1: code0 -> NOP (0xd503201f)
data[0x00:0x04] = b'\x1f\x20\x03\xd5'
print(f"    ✓ code0 修复: 0x{orig_code0:08x} -> 0xd503201f (NOP)")

# 修复 2: text_offset -> 0 (与 FriendlyWrt 官方一致)
struct.pack_into('<Q', data, 0x08, 0)
print(f"    ✓ text_offset 修复: 0x{orig_text_off:x} -> 0")

# 修复 3: image_size -> 整个文件大小
struct.pack_into('<Q', data, 0x10, file_size)
print(f"    ✓ image_size 修复: {orig_img_size} -> {file_size}")

# 校验 code1 是否合法 B 指令
opcode = (orig_code1 >> 26) & 0x3F
if opcode == 0x05:
    # 是 B 指令，检查符号扩展后的偏移
    imm26 = orig_code1 & 0x03FFFFFF
    # 符号扩展
    if imm26 & 0x02000000:
        imm26 = imm26 - 0x04000000
    offset = imm26 * 4
    target = offset
    print(f"    ✓ code1 是合法 B 指令，跳转 +{target} bytes (0x{target:x})")
else:
    print(f"    ⚠ code1 opcode=0x{opcode:x} 不是 B 指令")

open(sys.argv[2], 'wb').write(data)
print(f"    → 已生成 patched Image: {file_size} bytes")
PYEOF

  [ ! -f "$WORK_DIR/patched.img" ] && { err "PE 修复失败"; exit 1; }

  # 加 KRNL 头
  IMG_SIZE=$(stat -c%s "$WORK_DIR/patched.img")
  SIZE_HEX=$(printf '%08x' "$IMG_SIZE")
  SIZE_LE=$(echo "$SIZE_HEX" | sed 's/\(..\)\(..\)\(..\)\(..\)/\4\3\2\1/')
  printf 'KRNL' > "$TARGET_DIR/kernel.img"
  printf "$SIZE_LE" | xxd -r -p >> "$TARGET_DIR/kernel.img"
  cat "$WORK_DIR/patched.img" >> "$TARGET_DIR/kernel.img"

elif [ "$(xxd -l 2 -p "$IMAGE_FILE")" = "1f8b" ]; then
  log "  >>> gzip 压缩，解压 + 修复头"
  gunzip -c "$IMAGE_FILE" > "$WORK_DIR/raw.img" 2>/dev/null || cp "$IMAGE_FILE" "$WORK_DIR/raw.img"
  # 对解压结果再次修复
  python3 - "$WORK_DIR/raw.img" "$WORK_DIR/patched.img" <<'PYEOF'
import sys, struct
data = bytearray(open(sys.argv[1], 'rb').read())
data[0x00:0x04] = b'\x1f\x20\x03\xd5'
struct.pack_into('<Q', data, 0x08, 0)
struct.pack_into('<Q', data, 0x10, len(data))
open(sys.argv[2], 'wb').write(data)
PYEOF
  IMG_SIZE=$(stat -c%s "$WORK_DIR/patched.img")
  SIZE_HEX=$(printf '%08x' "$IMG_SIZE")
  SIZE_LE=$(echo "$SIZE_HEX" | sed 's/\(..\)\(..\)\(..\)\(..\)/\4\3\2\1/')
  printf 'KRNL' > "$TARGET_DIR/kernel.img"
  printf "$SIZE_LE" | xxd -r -p >> "$TARGET_DIR/kernel.img"
  cat "$WORK_DIR/patched.img" >> "$TARGET_DIR/kernel.img"

else
  log "  >>> 未知 magic，作为纯 Image + NOP 修复"
  python3 - "$IMAGE_FILE" "$WORK_DIR/patched.img" <<'PYEOF'
import sys, struct
data = bytearray(open(sys.argv[1], 'rb').read())
data[0x00:0x04] = b'\x1f\x20\x03\xd5'
struct.pack_into('<Q', data, 0x08, 0)
struct.pack_into('<Q', data, 0x10, len(data))
open(sys.argv[2], 'wb').write(data)
PYEOF
  IMG_SIZE=$(stat -c%s "$WORK_DIR/patched.img")
  SIZE_HEX=$(printf '%08x' "$IMG_SIZE")
  SIZE_LE=$(echo "$SIZE_HEX" | sed 's/\(..\)\(..\)\(..\)\(..\)/\4\3\2\1/')
  printf 'KRNL' > "$TARGET_DIR/kernel.img"
  printf "$SIZE_LE" | xxd -r -p >> "$TARGET_DIR/kernel.img"
  cat "$WORK_DIR/patched.img" >> "$TARGET_DIR/kernel.img"
fi

# 最终验证
log "  ========== 最终 kernel.img 验证 =========="
python3 - "$TARGET_DIR/kernel.img" <<'PYEOF'
import sys, struct
data = open(sys.argv[1], 'rb').read(128)
assert data[0:4] == b'KRNL', 'KRNL missing!'
knl_size = struct.unpack_from('<I', data, 4)[0]
code0 = struct.unpack_from('<I', data, 8)[0]   # 8 = 4(KRNL) + 4(size)
code1 = struct.unpack_from('<I', data, 12)[0]
text_off = struct.unpack_from('<Q', data, 16)[0]
img_size = struct.unpack_from('<Q', data, 24)[0]
flags = struct.unpack_from('<Q', data, 32)[0]
magic_pos = data.find(b'ARM\x64')

print(f"    KRNL size:       {knl_size}")
print(f"    code0:           0x{code0:08x}  {'✓ NOP' if code0 == 0xd503201f else '✗'}")
print(f"    code1:           0x{code1:08x}")
print(f"    text_offset:     0x{text_off:x}")
print(f"    image_size:      {img_size}")
print(f"    flags:           0x{flags:x}")
print(f"    ARM64 magic@:    0x{magic_pos:x}  {'✓' if magic_pos == 0x40 else '✗ 期望 0x40'}")

assert code0 == 0xd503201f, 'code0 修复失败'
assert img_size == knl_size, f'image_size ({img_size}) != KRNL size ({knl_size})'
assert magic_pos == 0x40, f'magic 位置错误'
print("    ✓✓✓ 所有断言通过")
PYEOF

log "  新 kernel.img: $(stat -c%s "$TARGET_DIR/kernel.img") bytes"

# ============================================================
# 5. dtb + uInitrd + parameter.txt
# ============================================================
log "========== [5/6] dtb + uInitrd + parameter =========="

if [ "$SLIM_MODE" = "true" ]; then
  DTB_R5S=$(find "$KERNEL_CACHE/dtb" -name "rk3568-nanopi-r5s.dtb" | head -1)
  DTB_R5C=$(find "$KERNEL_CACHE/dtb" -name "rk3568-nanopi-r5c.dtb" | head -1)
  log "  r5s: ${DTB_R5S:-未找到}"
  log "  r5c: ${DTB_R5C:-未找到}"
  if [ -n "$DTB_R5S" ] || [ -n "$DTB_R5C" ]; then
    [ -d "$TARGET_DIR/dtb/rockchip" ] && {
      rm -rf "$TARGET_DIR/dtb/rockchip"
      mkdir -p "$TARGET_DIR/dtb/rockchip"
      [ -n "$DTB_R5S" ] && cp -f "$DTB_R5S" "$TARGET_DIR/dtb/rockchip/"
      [ -n "$DTB_R5C" ] && cp -f "$DTB_R5C" "$TARGET_DIR/dtb/rockchip/"
      log "  ✓ dtb 已替换"
    }
  fi
fi

UINITRD=$(find "$KERNEL_CACHE/boot" -name "uInitrd-*" | head -1)
[ -n "$UINITRD" ] && cp "$UINITRD" "$TARGET_DIR/uInitrd" && log "  ✓ uInitrd 已替换"

PARAM="$TARGET_DIR/parameter.txt"
ORIG='0x00014000@0x00012000(kernel),0x00010000@0x00026000(boot),0x00010000@0x00036000(recovery),0x00200000@0x00046000(rootfs),0x00200000@0x00246000(userdata:grow),-@0x00446000(opt:grow)'
NEW='0x00018000@0x00012000(kernel),0x00010000@0x0002a000(boot),0x00010000@0x0003a000(recovery),0x00200000@0x0004a000(rootfs),0x00200000@0x0024a000(userdata:grow),-@0x0044a000(opt:grow)'
grep -q "0x00018000@0x00012000(kernel)" "$PARAM" || sed -i "s|$ORIG|$NEW|" "$PARAM"
grep -q "0x00018000@0x00012000(kernel)" "$PARAM" && log "  ✓ parameter.txt OK"

# ============================================================
# 6. 生成镜像
# ============================================================
log "========== [6/6] 生成镜像 =========="
cd "$SDFUSE_DIR"
chmod +x mk-sd-image.sh
rm -f out/*.img
set +e
yes | ./mk-sd-image.sh "$DIST_NAME" > /tmp/mk-sd.log 2>&1
MK_EXIT=$?
set -e
echo "  mk-sd-image.sh exit=$MK_EXIT"
tail -20 /tmp/mk-sd.log

FOUND_IMG=$(find out -maxdepth 1 -name "*.img" -print -quit)
[ -z "$FOUND_IMG" ] && { err "未生成镜像"; exit 1; }
mv "$FOUND_IMG" "$OUTPUT_IMG"

# 验证最终镜像的 kernel 分区
KERNEL_OFFSET=$((0x12000 * 512))
log "  验证 kernel 分区 (偏移 $KERNEL_OFFSET)..."
python3 - "$OUTPUT_IMG" "$KERNEL_OFFSET" <<'PYEOF'
import sys, struct
img, off = sys.argv[1], int(sys.argv[2])
with open(img, 'rb') as f:
    f.seek(off)
    data = f.read(128)
assert data[0:4] == b'KRNL', 'KRNL missing!'
knl_size = struct.unpack_from('<I', data, 4)[0]
code0 = struct.unpack_from('<I', data, 8)[0]
img_size = struct.unpack_from('<Q', data, 24)[0]
magic_pos = data.find(b'ARM\x64')
print(f"    ✓ KRNL size={knl_size}")
print(f"    ✓ code0=0x{code0:08x} ({'NOP' if code0 == 0xd503201f else '??'})")
print(f"    ✓ image_size={img_size}")
print(f"    ✓ magic@0x{magic_pos:x}")
assert code0 == 0xd503201f and magic_pos == 0x40
print("    ✓✓✓ 最终镜像含正确修复的内核")
PYEOF

log "=========================================="
log "✓ 完成"
log "  内核: $MATCHED_VER (tag: $KERNEL_TAG)"
log "  输出: $OUTPUT_IMG ($(($(stat -c%s "$OUTPUT_IMG")/1024/1024)) MiB)"
log "=========================================="