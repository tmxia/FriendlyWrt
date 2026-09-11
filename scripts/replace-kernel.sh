#!/bin/bash
# replace-kernel.sh - 从 breakingbadboy/OpenWrt 下载内核并修复 EFI stub 头
#
# 用法:
#   replace-kernel.sh <images.tgz> <sdfuse-dir> <dist-name> <output-img>
#
# 环境变量:
#   TARGET_MODEL     - r5s (默认) / r5c
#   SLIM_MODE        - true (默认) / false
#   KERNEL_REPO      - breakingbadboy/OpenWrt (默认)
#   KERNEL_VERSION   - 6.12.y (默认) / 6.18.y
set -euo pipefail

VERSION="2026-09-11-v9-fulldtb"
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

log "参数:"
log "  images.tgz:      $(basename "$IMAGES_TGZ")"
log "  sd-fuse dir:     $SDFUSE_DIR"
log "  dist name:       $DIST_NAME"
log "  output img:      $OUTPUT_IMG"
log "  target model:    $TARGET_MODEL"
log "  slim mode:       $SLIM_MODE"
log "  kernel repo:     $KERNEL_REPO"
log "  kernel version:  $KERNEL_VERSION"

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
[ -z "$BASE_DIR" ] && { err "找不到顶层目录"; ls -la "$WORK_DIR/base"; exit 1; }
log "  顶层: $BASE_DIR"
ls -la "$BASE_DIR/" | sed 's/^/    /'

# ============================================================
# 2. 下载内核
# ============================================================
log "========== [2/6] 下载 $KERNEL_VERSION 内核 =========="

TAG_LIST=$(gh release list --limit 100 --repo "$KERNEL_REPO" --json tagName --jq '.[].tagName' 2>/dev/null || echo "")
[ -z "$TAG_LIST" ] && { err "无法列出 tag"; exit 1; }

log "  可用 tag:"
echo "$TAG_LIST" | head -20 | sed 's/^/    /'

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

  log "  解压后顶层内容:"
  ls -la "$LOCAL_KDIR/" | sed 's/^/    /'

  mkdir -p boot dtb modules
  for type in boot dtb modules; do
    TAR=$(find "$LOCAL_KDIR" -maxdepth 1 -name "${type}-*.tar.gz" | head -1)
    [ -z "$TAR" ] && [ "$type" = "dtb" ] && TAR=$(find "$LOCAL_KDIR" -maxdepth 1 -name "dtb-rockchip-*.tar.gz" | head -1)
    [ -n "$TAR" ] && tar xzf "$TAR" -C "$type" && log "  ✓ 解压 $type: $(basename "$TAR")"
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
log "  已复制: $TARGET_DIR"

# ============================================================
# 4. 构造 kernel.img（修复 EFI stub）
# ============================================================
log "========== [4/6] 构造 kernel.img =========="

IMAGE_FILE=""
for pattern in "Image" "vmlinuz-*" "kernel*.img" "*.bin" "Image-*"; do
  IMAGE_FILE=$(find "$KERNEL_CACHE" -maxdepth 4 -name "$pattern" -type f 2>/dev/null | head -1)
  [ -n "$IMAGE_FILE" ] && break
done
[ -z "$IMAGE_FILE" ] && { err "找不到内核 Image"; find "$KERNEL_CACHE" -type f -name "vmlinuz*" -o -name "Image*" | head -10; exit 1; }

IMAGE_SIZE=$(stat -c%s "$IMAGE_FILE")
log "  内核文件: $(basename "$IMAGE_FILE") ($IMAGE_SIZE bytes)"
log "  类型: $(file -b "$IMAGE_FILE")"
log "  前 64 字节:"
xxd -l 64 "$IMAGE_FILE" | sed 's/^/    /'

MAGIC=$(xxd -l 4 -p "$IMAGE_FILE")
log "  magic: $MAGIC"

if [ "$MAGIC" = "4b524e4c" ]; then
  log "  >>> KRNL 格式，直接使用"
  cp "$IMAGE_FILE" "$TARGET_DIR/kernel.img"

elif [ "$MAGIC" = "d00dfeed" ]; then
  log "  >>> FIT 格式，直接使用"
  cp "$IMAGE_FILE" "$TARGET_DIR/kernel.img"

elif [ "$(xxd -l 2 -p "$IMAGE_FILE")" = "4d5a" ]; then
  log "  >>> PE/EFI stub 格式，修复 ARM64 Image 头..."
  python3 - "$IMAGE_FILE" "$WORK_DIR/patched.img" <<'PYEOF'
import sys, struct

data = bytearray(open(sys.argv[1], 'rb').read())
file_size = len(data)

orig_code0 = struct.unpack_from('<I', data, 0x00)[0]
orig_code1 = struct.unpack_from('<I', data, 0x04)[0]
orig_text_off = struct.unpack_from('<Q', data, 0x08)[0]
orig_img_size = struct.unpack_from('<Q', data, 0x10)[0]
orig_flags = struct.unpack_from('<Q', data, 0x18)[0]
magic_pos = data.find(b'ARM\x64')

print(f"    原 code0:       0x{orig_code0:08x}")
print(f"    原 code1:       0x{orig_code1:08x}")
print(f"    原 text_offset: 0x{orig_text_off:x} ({orig_text_off})")
print(f"    原 image_size:  {orig_img_size} bytes")
print(f"    原 flags:       0x{orig_flags:x}")
print(f"    ARM64 magic@:   0x{magic_pos:x}")
print(f"    实际文件大小:   {file_size} bytes")
print("")

data[0x00:0x04] = b'\x1f\x20\x03\xd5'
print(f"    ✓ code0 修复: 0x{orig_code0:08x} -> 0xd503201f (NOP)")

struct.pack_into('<Q', data, 0x08, 0)
print(f"    ✓ text_offset 修复: 0x{orig_text_off:x} -> 0")

struct.pack_into('<Q', data, 0x10, file_size)
print(f"    ✓ image_size 修复: {orig_img_size} -> {file_size}")

opcode = (orig_code1 >> 26) & 0x3F
if opcode == 0x05:
    imm26 = orig_code1 & 0x03FFFFFF
    if imm26 & 0x02000000:
        imm26 = imm26 - 0x04000000
    offset = imm26 * 4
    print(f"    ✓ code1 是合法 B 指令，跳转 +{offset} bytes (0x{offset:x})")

open(sys.argv[2], 'wb').write(data)
print(f"    → 已生成 patched Image: {file_size} bytes")
PYEOF

  [ ! -f "$WORK_DIR/patched.img" ] && { err "PE 修复失败"; exit 1; }

  IMG_SIZE=$(stat -c%s "$WORK_DIR/patched.img")
  SIZE_HEX=$(printf '%08x' "$IMG_SIZE")
  SIZE_LE=$(echo "$SIZE_HEX" | sed 's/\(..\)\(..\)\(..\)\(..\)/\4\3\2\1/')
  printf 'KRNL' > "$TARGET_DIR/kernel.img"
  printf "$SIZE_LE" | xxd -r -p >> "$TARGET_DIR/kernel.img"
  cat "$WORK_DIR/patched.img" >> "$TARGET_DIR/kernel.img"

elif [ "$(xxd -l 2 -p "$IMAGE_FILE")" = "1f8b" ]; then
  log "  >>> gzip 压缩，解压 + 修复头"
  gunzip -c "$IMAGE_FILE" > "$WORK_DIR/raw.img" 2>/dev/null || cp "$IMAGE_FILE" "$WORK_DIR/raw.img"
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
  log "  >>> 未知格式，作为纯 Image + NOP 修复"
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
code0 = struct.unpack_from('<I', data, 8)[0]
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
# 5. dtb + uInitrd + parameter（全目录搜索）
# ============================================================
log "========== [5/6] dtb + uInitrd + parameter =========="

log "  诊断: KERNEL_CACHE 完整结构"
log "    KERNEL_CACHE=$KERNEL_CACHE"
log "    顶层内容:"
ls -la "$KERNEL_CACHE/" | sed 's/^/      /'

log "    dtb 目录:"
ls -la "$KERNEL_CACHE/dtb/" 2>/dev/null | head -20 | sed 's/^/      /' || echo "      (无 dtb 目录)"

log "    全目录搜索所有 .dtb (前 30):"
find "$KERNEL_CACHE" -type f -name "*.dtb" 2>/dev/null | head -30 | sed 's/^/      /' || true

log "    全目录搜索 rk3568-nanopi-* :"
find "$KERNEL_CACHE" -type f -name "rk3568-nanopi-*" 2>/dev/null | sed 's/^/      /' || true

log "    全目录搜索 *r5s* :"
find "$KERNEL_CACHE" -type f -name "*r5s*" 2>/dev/null | sed 's/^/      /' || true

log "    全目录搜索 *r5c* :"
find "$KERNEL_CACHE" -type f -name "*r5c*" 2>/dev/null | sed 's/^/      /' || true

# 实际查找
DTB_R5S=$(find "$KERNEL_CACHE" -type f -name "rk3568-nanopi-r5s.dtb" 2>/dev/null | head -1)
DTB_R5C=$(find "$KERNEL_CACHE" -type f -name "rk3568-nanopi-r5c.dtb" 2>/dev/null | head -1)

log "  查找结果:"
log "    r5s: ${DTB_R5S:-未找到}"
log "    r5c: ${DTB_R5C:-未找到}"

# 如果找不到，尝试从 ophub/kernel 下载
if [ -z "$DTB_R5S" ] && [ -z "$DTB_R5C" ]; then
  log "  ⚠ 内核包中未找到，尝试从 ophub/kernel kernel_flippy ${MATCHED_VER} 下载..."
  FLIPPY_DTB_CACHE="/tmp/flippy-dtb-${MATCHED_VER}"
  if [ ! -f "$FLIPPY_DTB_CACHE/.ready" ]; then
    mkdir -p "$FLIPPY_DTB_CACHE"
    cd "$FLIPPY_DTB_CACHE"
    URL="https://github.com/ophub/kernel/releases/download/kernel_flippy/${MATCHED_VER}.tar.gz"
    if wget -q --timeout=60 "$URL" -O flippy.tar.gz 2>/dev/null; then
      tar xzf flippy.tar.gz 2>/dev/null
      LOCAL_FLIPPY="${MATCHED_VER}"
      [ ! -d "$LOCAL_FLIPPY" ] && LOCAL_FLIPPY=$(find . -maxdepth 1 -type d -name "*${MATCHED_VER}*" | head -1)
      DTB_FLIPPY_TAR=$(find "$LOCAL_FLIPPY" -name "dtb-rockchip-*.tar.gz" 2>/dev/null | head -1)
      if [ -n "$DTB_FLIPPY_TAR" ]; then
        mkdir -p dtb
        tar xzf "$DTB_FLIPPY_TAR" -C dtb
        touch .ready
        log "    ✓ flippy dtb 下载并解压"
      fi
    else
      log "    ✗ flippy ${MATCHED_VER} 下载失败"
    fi
  fi
  if [ -d "$FLIPPY_DTB_CACHE/dtb" ]; then
    DTB_R5S=$(find "$FLIPPY_DTB_CACHE" -type f -name "rk3568-nanopi-r5s.dtb" | head -1)
    DTB_R5C=$(find "$FLIPPY_DTB_CACHE" -type f -name "rk3568-nanopi-r5c.dtb" | head -1)
    log "    flippy 缓存查找: r5s=${DTB_R5S:-未找到}, r5c=${DTB_R5C:-未找到}"
  fi
fi

# 替换 dtb
if [ -n "$DTB_R5S" ] || [ -n "$DTB_R5C" ]; then
  log "  替换 dtb 到骨架..."
  if [ ! -d "$TARGET_DIR/dtb/rockchip" ]; then
    mkdir -p "$TARGET_DIR/dtb/rockchip"
  fi
  BEFORE=$(find "$TARGET_DIR/dtb" -type f -name "*.dtb" 2>/dev/null | wc -l)
  rm -rf "$TARGET_DIR/dtb/rockchip"
  mkdir -p "$TARGET_DIR/dtb/rockchip"
  if [ -n "$DTB_R5S" ]; then
    cp -f "$DTB_R5S" "$TARGET_DIR/dtb/rockchip/rk3568-nanopi-r5s.dtb"
    log "    ✓ r5s: $(basename "$DTB_R5S") -> rk3568-nanopi-r5s.dtb"
  fi
  if [ -n "$DTB_R5C" ]; then
    cp -f "$DTB_R5C" "$TARGET_DIR/dtb/rockchip/rk3568-nanopi-r5c.dtb"
    log "    ✓ r5c: $(basename "$DTB_R5C") -> rk3568-nanopi-r5c.dtb"
  fi
  AFTER=$(find "$TARGET_DIR/dtb" -type f -name "*.dtb" 2>/dev/null | wc -l)
  log "    dtb 数量: $BEFORE -> $AFTER"
  ls -la "$TARGET_DIR/dtb/rockchip/" | sed 's/^/      /'
else
  log "  ✗✗✗ 无法找到 r5s/r5c dtb，保留骨架 dtb"
  log "  这极可能导致启动失败！"
fi

# uInitrd
UINITRD=$(find "$KERNEL_CACHE" -type f -name "uInitrd-*" | head -1)
if [ -n "$UINITRD" ]; then
  cp "$UINITRD" "$TARGET_DIR/uInitrd"
  log "  ✓ uInitrd: $(stat -c%s "$TARGET_DIR/uInitrd") bytes"
else
  INITRD=$(find "$KERNEL_CACHE" -type f -name "initrd.img-*" | head -1)
  if [ -n "$INITRD" ] && command -v mkimage >/dev/null 2>&1; then
    log "  从 initrd.img 转换..."
    mkimage -A arm64 -O linux -T ramdisk -C gzip -n "uInitrd" -d "$INITRD" "$TARGET_DIR/uInitrd" 2>/dev/null || \
      cp "$INITRD" "$TARGET_DIR/uInitrd"
    log "  ✓ uInitrd: $(stat -c%s "$TARGET_DIR/uInitrd") bytes"
  else
    warn "  找不到 uInitrd，保留骨架"
  fi
fi

# parameter.txt
PARAM="$TARGET_DIR/parameter.txt"
ORIG='0x00014000@0x00012000(kernel),0x00010000@0x00026000(boot),0x00010000@0x00036000(recovery),0x00200000@0x00046000(rootfs),0x00200000@0x00246000(userdata:grow),-@0x00446000(opt:grow)'
NEW='0x00018000@0x00012000(kernel),0x00010000@0x0002a000(boot),0x00010000@0x0003a000(recovery),0x00200000@0x0004a000(rootfs),0x00200000@0x0024a000(userdata:grow),-@0x0044a000(opt:grow)'
if ! grep -q "0x00018000@0x00012000(kernel)" "$PARAM"; then
  sed -i "s|$ORIG|$NEW|" "$PARAM"
fi
grep -q "0x00018000@0x00012000(kernel)" "$PARAM" && log "  ✓ parameter.txt OK"

log "  最终目录内容:"
ls -la "$TARGET_DIR/" | sed 's/^/    /'

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
tail -30 /tmp/mk-sd.log | sed 's/^/    /'

FOUND_IMG=$(find out -maxdepth 1 -name "*.img" -print -quit)
[ -z "$FOUND_IMG" ] && { err "未生成镜像"; ls -la out/; exit 1; }
mv "$FOUND_IMG" "$OUTPUT_IMG"

# 验证最终镜像
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
log "✓ 完成 (version $VERSION)"
log "  内核 tag: $KERNEL_TAG"
log "  内核版本: $MATCHED_VER"
log "  r5s dtb: ${DTB_R5S:-未找到}"
log "  r5c dtb: ${DTB_R5C:-未找到}"
log "  输出: $OUTPUT_IMG ($(($(stat -c%s "$OUTPUT_IMG")/1024/1024)) MiB)"
log "=========================================="