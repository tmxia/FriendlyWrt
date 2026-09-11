#!/bin/bash
# replace-kernel.sh - 使用 breakingbadboy 内核替换 FriendlyWrt kernel.img（最小化修改）
set -euo pipefail

VERSION="2026-09-11-v11-minimal"
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

KERNEL_TAG=""
for t in kernel_stable kernel_rk35xx kernel_rk3588 kernel_flippy; do
  echo "$TAG_LIST" | grep -qx "$t" && { KERNEL_TAG="$t"; break; }
done
[ -z "$KERNEL_TAG" ] && KERNEL_TAG=$(echo "$TAG_LIST" | grep -E '^kernel_' | head -1)
[ -z "$KERNEL_TAG" ] && { err "找不到 kernel_* tag"; exit 1; }
log "  选中 tag: $KERNEL_TAG"

ASSETS=$(gh release view "$KERNEL_TAG" --repo "$KERNEL_REPO" --json assets --jq '.assets[].name' 2>/dev/null || echo "")
VERSION_PREFIX="${KERNEL_VERSION%.y}"
MATCHED_VER=$(echo "$ASSETS" | grep -E "^${VERSION_PREFIX}\.[0-9]+\.tar\.gz$" | sed 's/\.tar\.gz//' | sort -V | tail -1)
[ -z "$MATCHED_VER" ] && { err "找不到 $KERNEL_VERSION"; echo "$ASSETS" | head -20; exit 1; }
log "  匹配版本: $MATCHED_VER"

KERNEL_CACHE="/tmp/kernel-cache-${KERNEL_TAG}/${MATCHED_VER}"
if [ ! -f "$KERNEL_CACHE/.ready" ]; then
  rm -rf "$KERNEL_CACHE"
  mkdir -p "$KERNEL_CACHE"
  cd "$KERNEL_CACHE"
  URL="https://github.com/${KERNEL_REPO}/releases/download/${KERNEL_TAG}/${MATCHED_VER}.tar.gz"
  log "  下载 $URL"
  wget -q --timeout=120 "$URL" -O kernel.tar.gz 2>/dev/null || curl -L -f --max-time 300 "$URL" -o kernel.tar.gz
  tar xzf kernel.tar.gz

  LOCAL_KDIR="$MATCHED_VER"
  [ ! -d "$LOCAL_KDIR" ] && LOCAL_KDIR=$(find . -maxdepth 2 -type d -name "*${MATCHED_VER}*" ! -path "./boot*" ! -path "./dtb*" ! -path "./modules*" | head -1)
  echo "$KERNEL_CACHE/$LOCAL_KDIR" > "$KERNEL_CACHE/.topdir"

  # 解压 boot 和 dtb（必须）
  for type in boot dtb; do
    TAR=$(find "$LOCAL_KDIR" -maxdepth 1 -name "${type}-*.tar.gz" | head -1)
    [ -z "$TAR" ] && [ "$type" = "dtb" ] && TAR=$(find "$LOCAL_KDIR" -maxdepth 1 -name "dtb-rockchip-*.tar.gz" | head -1)
    [ -n "$TAR" ] && tar xzf "$TAR" -C "$KERNEL_CACHE" && log "  ✓ 解压 $type: $(basename "$TAR")"
  done

  touch .ready
fi
KERNEL_TOPDIR=$(cat "$KERNEL_CACHE/.topdir" 2>/dev/null || echo "$KERNEL_CACHE/$MATCHED_VER")
log "  缓存: $KERNEL_CACHE"

# ============================================================
# 3. 复制骨架
# ============================================================
log "========== [3/6] 复制骨架 =========="
TARGET_DIR="$SDFUSE_DIR/$DIST_NAME"
rm -rf "$TARGET_DIR"
cp -a "$BASE_DIR" "$TARGET_DIR"

# ============================================================
# 4. 构造 kernel.img（只改 code0）
# ============================================================
log "========== [4/6] 构造 kernel.img（仅修复 code0）=========="

IMAGE_FILE=""
for pattern in "vmlinuz-*" "Image" "Image-*"; do
  IMAGE_FILE=$(find "$KERNEL_CACHE" -maxdepth 3 -type f -name "$pattern" 2>/dev/null | head -1)
  [ -n "$IMAGE_FILE" ] && break
done
[ -z "$IMAGE_FILE" ] && { err "找不到内核 Image"; find "$KERNEL_CACHE" -type f -name "vmlinuz*"; exit 1; }

IMAGE_SIZE=$(stat -c%s "$IMAGE_FILE")
log "  内核文件: $(basename "$IMAGE_FILE") ($IMAGE_SIZE bytes)"
log "  前 64 字节:"
xxd -l 64 "$IMAGE_FILE" | sed 's/^/    /'

MAGIC=$(xxd -l 4 -p "$IMAGE_FILE")
log "  magic: $MAGIC"

if [ "$MAGIC" = "4b524e4c" ]; then
  log "  >>> 已是 KRNL，直接使用"
  cp "$IMAGE_FILE" "$TARGET_DIR/kernel.img"

elif [ "$MAGIC" = "d00dfeed" ]; then
  log "  >>> FIT，直接使用"
  cp "$IMAGE_FILE" "$TARGET_DIR/kernel.img"

elif [ "$(xxd -l 2 -p "$IMAGE_FILE")" = "4d5a" ]; then
  log "  >>> PE/EFI stub，仅修复 code0 (保留 text_offset 和 image_size)"
  python3 - "$IMAGE_FILE" "$WORK_DIR/patched.img" <<'PYEOF'
import sys, struct
data = bytearray(open(sys.argv[1], 'rb').read())

code0 = struct.unpack_from('<I', data, 0x00)[0]
code1 = struct.unpack_from('<I', data, 0x04)[0]
text_off = struct.unpack_from('<Q', data, 0x08)[0]
img_size = struct.unpack_from('<Q', data, 0x10)[0]
magic_pos = data.find(b'ARM\x64')

print(f"    原 code0:      0x{code0:08x}")
print(f"    原 code1:      0x{code1:08x}")
print(f"    原 text_offset: 0x{text_off:x} ({text_off})")
print(f"    原 image_size:  {img_size} bytes ({img_size//1024//1024} MiB)")
print(f"    ARM64 magic@:   0x{magic_pos:x}")

# 仅修改 code0 → NOP
data[0x00:0x04] = b'\x1f\x20\x03\xd5'
print(f"    ✓ code0 -> NOP")
print(f"    ✓ text_offset 保留: 0x{text_off:x}")
print(f"    ✓ image_size 保留: {img_size}")

open(sys.argv[2], 'wb').write(data)
PYEOF

  IMG_SIZE=$(stat -c%s "$WORK_DIR/patched.img")
  SIZE_HEX=$(printf '%08x' "$IMG_SIZE")
  SIZE_LE=$(echo "$SIZE_HEX" | sed 's/\(..\)\(..\)\(..\)\(..\)/\4\3\2\1/')
  printf 'KRNL' > "$TARGET_DIR/kernel.img"
  printf "$SIZE_LE" | xxd -r -p >> "$TARGET_DIR/kernel.img"
  cat "$WORK_DIR/patched.img" >> "$TARGET_DIR/kernel.img"
else
  log "  >>> 未知格式，按原样使用"
  IMG_SIZE=$IMAGE_SIZE
  SIZE_HEX=$(printf '%08x' "$IMG_SIZE")
  SIZE_LE=$(echo "$SIZE_HEX" | sed 's/\(..\)\(..\)\(..\)\(..\)/\4\3\2\1/')
  printf 'KRNL' > "$TARGET_DIR/kernel.img"
  printf "$SIZE_LE" | xxd -r -p >> "$TARGET_DIR/kernel.img"
  cat "$IMAGE_FILE" >> "$TARGET_DIR/kernel.img"
fi

# 验证
log "  ========== kernel.img 验证 =========="
python3 - "$TARGET_DIR/kernel.img" <<'PYEOF'
import sys, struct
data = open(sys.argv[1], 'rb').read(128)
assert data[0:4] == b'KRNL', 'KRNL missing'
knl_size = struct.unpack_from('<I', data, 4)[0]
code0 = struct.unpack_from('<I', data, 8)[0]
code1 = struct.unpack_from('<I', data, 12)[0]
text_off = struct.unpack_from('<Q', data, 16)[0]
img_size = struct.unpack_from('<Q', data, 24)[0]
magic_pos = data.find(b'ARM\x64')
print(f"    KRNL size:   {knl_size}")
print(f"    code0:       0x{code0:08x}  {'✓ NOP' if code0 == 0xd503201f else '✗'}")
print(f"    code1:       0x{code1:08x}")
print(f"    text_offset: 0x{text_off:x}")
print(f"    image_size:  {img_size}")
print(f"    magic@:      0x{magic_pos:x}")
assert code0 == 0xd503201f and magic_pos == 0x40
print("    ✓✓✓ 断言通过")
PYEOF

# ============================================================
# 5. dtb + uInitrd（不改 parameter.txt）
# ============================================================
log "========== [5/6] dtb + uInitrd（保留 parameter.txt）=========="

# dtb 提取
DTB_TAR=""
for search_dir in "$KERNEL_TOPDIR" "$KERNEL_CACHE"; do
  DTB_TAR=$(find "$search_dir" -maxdepth 2 -name "dtb-rockchip-*.tar.gz" 2>/dev/null | head -1)
  [ -n "$DTB_TAR" ] && break
done
[ -z "$DTB_TAR" ] && { err "找不到 dtb-rockchip 包"; exit 1; }
log "  dtb 包: $DTB_TAR"

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

# uInitrd —— 关键改动：使用 FriendlyWrt 原版，不用 flippy 的
log "  ⚠ uInitrd: 保留 FriendlyWrt 原版（避免 flippy initrd 与 rootfs 冲突）"
log "    FriendlyWrt 原 uInitrd 位置: boot.img 内"
# 不做任何 uInitrd 替换

# 不改 parameter.txt
log "  parameter.txt: 保留 FriendlyWrt 原版（kernel 分区 40 MiB）"
grep CMDLINE "$TARGET_DIR/parameter.txt" | head -1 | sed 's/^/    /'

log "  最终目录内容:"
ls -la "$TARGET_DIR/" | sed 's/^/    /'
log "  dtb/rockchip:"
ls -la "$TARGET_DIR/dtb/rockchip/" | sed 's/^/    /'

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

# 验证
KERNEL_OFFSET=$((0x12000 * 512))
log "  验证 kernel 分区 (偏移 $KERNEL_OFFSET)..."
python3 - "$OUTPUT_IMG" "$KERNEL_OFFSET" <<'PYEOF'
import sys, struct
img, off = sys.argv[1], int(sys.argv[2])
with open(img, 'rb') as f:
    f.seek(off)
    data = f.read(128)
assert data[0:4] == b'KRNL'
code0 = struct.unpack_from('<I', data, 8)[0]
text_off = struct.unpack_from('<Q', data, 16)[0]
img_size = struct.unpack_from('<Q', data, 24)[0]
magic_pos = data.find(b'ARM\x64')
print(f"    ✓ code0=0x{code0:08x} {'NOP' if code0 == 0xd503201f else '?'}")
print(f"    ✓ text_offset=0x{text_off:x}")
print(f"    ✓ image_size={img_size}")
print(f"    ✓ magic@0x{magic_pos:x}")
assert code0 == 0xd503201f and magic_pos == 0x40
print("    ✓✓✓ 最终镜像 OK")
PYEOF

log "=========================================="
log "✓ 完成 (version $VERSION)"
log "  内核: $MATCHED_VER"
log "  r5s dtb: 已替换"
log "  uInitrd: 保留 FriendlyWrt 原版"
log "  parameter.txt: 保留原版（kernel 40 MiB）"
log "  输出: $OUTPUT_IMG"
log "=========================================="