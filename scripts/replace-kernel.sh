#!/bin/bash
# replace-kernel.sh - 使用 ophub/kernel 的 kernel_rk35xx 替换 FriendlyWrt kernel.img
#
# 用法:
#   replace-kernel.sh <images.tgz> <sdfuse-dir> <dist-name> <output-img>
#
# 环境变量:
#   KERNEL_REPO      - ophub/kernel (默认)
#   KERNEL_RELEASE   - kernel_rk35xx (默认)
#   TARGET_MODEL     - r5s (默认) / r5c
set -euo pipefail

VERSION="2026-09-11-v12-rk35xx"
log() { echo -e "\033[0;32m[replace]\033[0m $*"; }
warn() { echo -e "\033[0;33m[replace]\033[0m $*"; }
err() { echo -e "\033[0;31m[replace]\033[0m $*" >&2; }
log "replace-kernel.sh version: $VERSION"

IMAGES_TGZ="$1"
SDFUSE_DIR="$2"
DIST_NAME="$3"
OUTPUT_IMG="$4"
TARGET_MODEL="${TARGET_MODEL:-r5s}"
KERNEL_REPO="${KERNEL_REPO:-ophub/kernel}"
KERNEL_RELEASE="${KERNEL_RELEASE:-kernel_rk35xx}"

log "参数:"
log "  images.tgz:      $(basename "$IMAGES_TGZ")"
log "  sd-fuse dir:     $SDFUSE_DIR"
log "  dist name:       $DIST_NAME"
log "  output img:      $OUTPUT_IMG"
log "  kernel repo:     $KERNEL_REPO"
log "  kernel release:  $KERNEL_RELEASE"
log "  target model:    $TARGET_MODEL"

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
ls -la "$BASE_DIR/" | sed 's/^/    /'

# ============================================================
# 2. 下载 kernel_rk35xx
# ============================================================
log "========== [2/6] 下载 $KERNEL_RELEASE 内核 =========="

TAG_LIST=$(gh release list --limit 100 --repo "$KERNEL_REPO" --json tagName --jq '.[].tagName' 2>/dev/null || echo "")
[ -z "$TAG_LIST" ] && { err "无法列出 tag"; exit 1; }

log "  可用 tag:"
echo "$TAG_LIST" | head -20 | sed 's/^/    /'

if ! echo "$TAG_LIST" | grep -qx "$KERNEL_RELEASE"; then
  err "  $KERNEL_REPO 中不存在 tag: $KERNEL_RELEASE"
  exit 1
fi
log "  使用 tag: $KERNEL_RELEASE"

ASSETS=$(gh release view "$KERNEL_RELEASE" --repo "$KERNEL_REPO" --json assets --jq '.assets[].name' 2>/dev/null || echo "")
[ -z "$ASSETS" ] && { err "无法获取 assets"; exit 1; }

log "  可用内核包（前 20）:"
echo "$ASSETS" | head -20 | sed 's/^/    /'

# 优先 6.1.x（rk35xx 主线稳定版），也接受 6.6.x
MATCHED_VER=$(echo "$ASSETS" | grep -E '^6\.1\.[0-9]+\.tar\.gz$' | sed 's/\.tar\.gz//' | sort -V | tail -1)
[ -z "$MATCHED_VER" ] && MATCHED_VER=$(echo "$ASSETS" | grep -E '^6\.[0-9]+\.[0-9]+\.tar\.gz$' | sed 's/\.tar\.gz//' | sort -V | tail -1)
[ -z "$MATCHED_VER" ] && { err "找不到 6.x 版本"; exit 1; }
log "  匹配版本: $MATCHED_VER"

KERNEL_CACHE="/tmp/kernel-cache-${KERNEL_RELEASE}/${MATCHED_VER}"
if [ ! -f "$KERNEL_CACHE/.ready" ]; then
  log "  下载 $MATCHED_VER..."
  rm -rf "$KERNEL_CACHE"
  mkdir -p "$KERNEL_CACHE"
  cd "$KERNEL_CACHE"
  URL="https://github.com/${KERNEL_REPO}/releases/download/${KERNEL_RELEASE}/${MATCHED_VER}.tar.gz"
  log "  URL: $URL"

  DOWNLOAD_OK=false
  wget -q --timeout=120 --tries=2 "$URL" -O kernel.tar.gz 2>/dev/null && DOWNLOAD_OK=true
  [ "$DOWNLOAD_OK" != "true" ] && curl -L -f --connect-timeout 60 --max-time 300 "$URL" -o kernel.tar.gz 2>/dev/null && DOWNLOAD_OK=true
  [ "$DOWNLOAD_OK" != "true" ] && { err "下载失败"; exit 1; }

  tar xzf kernel.tar.gz || { err "解压失败"; exit 1; }

  log "  解压后内容:"
  ls -la | sed 's/^/    /'

  LOCAL_KDIR="$MATCHED_VER"
  [ ! -d "$LOCAL_KDIR" ] && LOCAL_KDIR=$(find . -maxdepth 2 -type d -name "*${MATCHED_VER}*" ! -path "./boot*" ! -path "./dtb*" ! -path "./modules*" | head -1)
  [ -z "$LOCAL_KDIR" ] && { err "找不到内核目录"; exit 1; }

  log "  内核目录内容:"
  ls -la "$LOCAL_KDIR/" | sed 's/^/    /'

  echo "$KERNEL_CACHE/$LOCAL_KDIR" > "$KERNEL_CACHE/.topdir"

  # 解压 boot 和 dtb
  for type in boot dtb modules; do
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
log "  已复制: $TARGET_DIR"

# ============================================================
# 4. 构造 kernel.img
# ============================================================
log "========== [4/6] 构造 kernel.img =========="

# 找内核文件
IMAGE_FILE=""
for pattern in "Image" "vmlinuz-*" "kernel*.img" "*.bin" "Image-*"; do
  IMAGE_FILE=$(find "$KERNEL_CACHE" -maxdepth 3 -type f -name "$pattern" 2>/dev/null | head -1)
  [ -n "$IMAGE_FILE" ] && break
done
[ -z "$IMAGE_FILE" ] && { err "找不到内核 Image"; find "$KERNEL_CACHE" -type f -name "*Image*" -o -name "*vmlinuz*" -o -name "*.img" | head -20; exit 1; }

IMAGE_SIZE=$(stat -c%s "$IMAGE_FILE")
log "  内核文件: $(basename "$IMAGE_FILE") ($IMAGE_SIZE bytes)"
log "  类型: $(file -b "$IMAGE_FILE")"
log "  前 64 字节:"
xxd -l 64 "$IMAGE_FILE" | sed 's/^/    /'

MAGIC=$(xxd -l 4 -p "$IMAGE_FILE")
log "  magic: $MAGIC"

if [ "$MAGIC" = "4b524e4c" ]; then
  log "  >>> 已是 KRNL 格式，直接使用"
  cp "$IMAGE_FILE" "$TARGET_DIR/kernel.img"

elif [ "$MAGIC" = "d00dfeed" ]; then
  log "  >>> FIT 格式，直接使用"
  cp "$IMAGE_FILE" "$TARGET_DIR/kernel.img"

elif [ "$(xxd -l 2 -p "$IMAGE_FILE")" = "4d5a" ]; then
  log "  ⚠ 检测到 PE/EFI stub 格式 (kernel_rk35xx 意外情况)"
  log "  ⚠ 这表明 $KERNEL_RELEASE 的 $MATCHED_VER 也不是裸机格式"
  log "  尝试修复 code0 后使用..."
  python3 - "$IMAGE_FILE" "$WORK_DIR/patched.img" <<'PYEOF'
import sys, struct
data = bytearray(open(sys.argv[1], 'rb').read())
code0 = struct.unpack_from('<I', data, 0x00)[0]
data[0x00:0x04] = b'\x1f\x20\x03\xd5'
print(f"    ✓ code0: 0x{code0:08x} -> 0xd503201f")
open(sys.argv[2], 'wb').write(data)
PYEOF
  IMG_SIZE=$(stat -c%s "$WORK_DIR/patched.img")
  SIZE_HEX=$(printf '%08x' "$IMG_SIZE")
  SIZE_LE=$(echo "$SIZE_HEX" | sed 's/\(..\)\(..\)\(..\)\(..\)/\4\3\2\1/')
  printf 'KRNL' > "$TARGET_DIR/kernel.img"
  printf "$SIZE_LE" | xxd -r -p >> "$TARGET_DIR/kernel.img"
  cat "$WORK_DIR/patched.img" >> "$TARGET_DIR/kernel.img"

else
  # 裸机 ARM64 Image —— 完美情况
  log "  >>> 裸机 ARM64 Image，直接加 KRNL 头"
  SIZE_HEX=$(printf '%08x' "$IMAGE_SIZE")
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
assert data[0:4] == b'KRNL', 'KRNL missing!'
knl_size = struct.unpack_from('<I', data, 4)[0]
code0 = struct.unpack_from('<I', data, 8)[0]
magic_pos = data.find(b'ARM\x64')
print(f"    KRNL size: {knl_size}")
print(f"    code0:     0x{code0:08x}")
print(f"    magic@:    0x{magic_pos:x}")
assert magic_pos == 0x40, f'ARM64 magic 位置错误: 0x{magic_pos:x}'
print("    ✓✓✓ KRNL 头 OK")
PYEOF

log "  新 kernel.img: $(stat -c%s "$TARGET_DIR/kernel.img") bytes"

# ============================================================
# 5. dtb + uInitrd
# ============================================================
log "========== [5/6] dtb + uInitrd =========="

# dtb 提取
DTB_TAR=""
for search_dir in "$KERNEL_TOPDIR" "$KERNEL_CACHE"; do
  DTB_TAR=$(find "$search_dir" -maxdepth 2 -name "dtb-rockchip-*.tar.gz" 2>/dev/null | head -1)
  [ -n "$DTB_TAR" ] && break
done

if [ -n "$DTB_TAR" ]; then
  log "  dtb 包: $DTB_TAR"
  log "  包内 rk3568-nanopi-r5* 文件:"
  tar tzf "$DTB_TAR" | grep -E "rk3568-nanopi-r5" | sed 's/^/    /' || echo "    (无)"

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
else
  warn "  找不到 dtb-rockchip 包，保留骨架 dtb"
fi

# uInitrd
UINITRD=$(find "$KERNEL_CACHE" -type f -name "uInitrd-*" | head -1)
if [ -n "$UINITRD" ]; then
  cp "$UINITRD" "$TARGET_DIR/uInitrd"
  log "  ✓ uInitrd: $(stat -c%s "$TARGET_DIR/uInitrd") bytes"
else
  log "  ⚠ 内核包无 uInitrd，保留骨架（boot.img 内）"
fi

# parameter.txt 不动
log "  parameter.txt 保留原版"
grep CMDLINE "$TARGET_DIR/parameter.txt" | head -1 | sed 's/^/    /'

log "  最终目录:"
ls -la "$TARGET_DIR/" | sed 's/^/    /'
log "  dtb/rockchip:"
ls -la "$TARGET_DIR/dtb/rockchip/" 2>/dev/null | sed 's/^/    /'

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
magic_pos = data.find(b'ARM\x64')
print(f"    ✓ magic@0x{magic_pos:x}")
assert magic_pos == 0x40
print("    ✓✓✓ 最终镜像 OK")
PYEOF

log "=========================================="
log "✓ 完成 (version $VERSION)"
log "  内核 tag:  $KERNEL_RELEASE"
log "  内核版本:  $MATCHED_VER"
log "  输出:      $OUTPUT_IMG ($(($(stat -c%s "$OUTPUT_IMG")/1024/1024)) MiB)"
log "=========================================="