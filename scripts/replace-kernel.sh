#!/bin/bash
# replace-kernel.sh - 从 ophub/kernel 和 breakingbadboy/OpenWrt 扫描最新 6.1.x 内核
set -euo pipefail

VERSION="2026-09-11-v15-6.1-latest"
log() { echo -e "\033[0;32m[replace]\033[0m $*"; }
warn() { echo -e "\033[0;33m[replace]\033[0m $*"; }
err() { echo -e "\033[0;31m[replace]\033[0m $*" >&2; }
log "replace-kernel.sh version: $VERSION"

IMAGES_TGZ="$1"
SDFUSE_DIR="$2"
DIST_NAME="$3"
OUTPUT_IMG="$4"
TARGET_MODEL="${TARGET_MODEL:-r5s}"

log "参数: images=$(basename "$IMAGES_TGZ"), model=$TARGET_MODEL"

WORK_DIR=$(mktemp -d /tmp/replace-kernel.XXXXXX)
trap "rm -rf $WORK_DIR" EXIT
log "工作目录: $WORK_DIR"

# ============================================================
# 1. 解压官方 images tgz
# ============================================================
log "========== [1/7] 解压 images.tgz =========="
mkdir -p "$WORK_DIR/base"
tar xzf "$IMAGES_TGZ" -C "$WORK_DIR/base"
BASE_DIR=$(find "$WORK_DIR/base" -maxdepth 2 -type d -name "friendlywrt*" | head -1)
[ -z "$BASE_DIR" ] && { err "找不到顶层目录"; exit 1; }
log "  顶层: $BASE_DIR"

# ============================================================
# 2. 扫描两个仓库的 6.1.x 版本
# ============================================================
log "========== [2/7] 扫描 6.1.x 内核版本 =========="

declare -A VER_TO_SOURCE

SCAN_LIST=(
  "ophub/kernel:kernel_rk35xx"
  "ophub/kernel:kernel_flippy"
  "breakingbadboy/OpenWrt:kernel_rk35xx"
  "breakingbadboy/OpenWrt:kernel_stable"
)

for target in "${SCAN_LIST[@]}"; do
  REPO="${target%%:*}"
  RELEASE="${target##*:}"
  log "  扫描 $REPO / $RELEASE ..."

  ASSETS=$(gh release view "$RELEASE" --repo "$REPO" --json assets --jq '.assets[].name' 2>/dev/null || echo "")
  if [ -z "$ASSETS" ]; then
    log "    (无资产或不存在)"
    continue
  fi

  V61=$(echo "$ASSETS" | grep -E '^6\.1\.[0-9]+\.tar\.gz$' | sed 's/\.tar\.gz//' | sort -V || echo "")
  if [ -z "$V61" ]; then
    log "    (无 6.1.x)"
    continue
  fi

  log "    6.1.x 版本:"
  echo "$V61" | sed 's/^/      /'

  for v in $V61; do
    if [ -z "${VER_TO_SOURCE[$v]:-}" ]; then
      VER_TO_SOURCE["$v"]="$REPO:$RELEASE"
    fi
  done
done

if [ ${#VER_TO_SOURCE[@]} -eq 0 ]; then
  err "  两个仓库都没有 6.1.x 内核"
  exit 1
fi

log ""
log "  所有可用 6.1.x 版本（去重后）:"
for v in $(printf '%s\n' "${!VER_TO_SOURCE[@]}" | sort -V); do
  log "    $v  ← ${VER_TO_SOURCE[$v]}"
done

SELECTED_VER=$(printf '%s\n' "${!VER_TO_SOURCE[@]}" | sort -V | tail -1)
SELECTED_SOURCE="${VER_TO_SOURCE[$SELECTED_VER]}"
SELECTED_REPO="${SELECTED_SOURCE%%:*}"
SELECTED_RELEASE="${SELECTED_SOURCE##*:}"

log ""
log "  ============ 决策 ============"
log "  最新 6.1.x: $SELECTED_VER"
log "  来源: $SELECTED_REPO / $SELECTED_RELEASE"

# ============================================================
# 3. 下载选定版本
# ============================================================
log "========== [3/7] 下载 $SELECTED_VER =========="

KERNEL_CACHE="/tmp/kernel-cache-${SELECTED_RELEASE}/${SELECTED_VER}"
if [ ! -f "$KERNEL_CACHE/.ready" ]; then
  log "  下载 $SELECTED_VER from $SELECTED_REPO/$SELECTED_RELEASE..."
  rm -rf "$KERNEL_CACHE"
  mkdir -p "$KERNEL_CACHE"
  cd "$KERNEL_CACHE"
  URL="https://github.com/${SELECTED_REPO}/releases/download/${SELECTED_RELEASE}/${SELECTED_VER}.tar.gz"
  log "  URL: $URL"

  DOWNLOAD_OK=false
  wget -q --timeout=120 --tries=2 "$URL" -O kernel.tar.gz 2>/dev/null && DOWNLOAD_OK=true
  [ "$DOWNLOAD_OK" != "true" ] && curl -L -f --connect-timeout 60 --max-time 300 "$URL" -o kernel.tar.gz 2>/dev/null && DOWNLOAD_OK=true
  [ "$DOWNLOAD_OK" != "true" ] && { err "下载失败"; exit 1; }

  tar xzf kernel.tar.gz || { err "解压失败"; exit 1; }

  LOCAL_KDIR="$SELECTED_VER"
  [ ! -d "$LOCAL_KDIR" ] && LOCAL_KDIR=$(find . -maxdepth 2 -type d -name "*${SELECTED_VER}*" ! -path "./boot*" ! -path "./dtb*" ! -path "./modules*" | head -1)
  [ -z "$LOCAL_KDIR" ] && { err "找不到内核目录"; ls -la; exit 1; }

  log "  顶层内容:"
  ls -la "$LOCAL_KDIR/" | sed 's/^/    /'

  echo "$KERNEL_CACHE/$LOCAL_KDIR" > "$KERNEL_CACHE/.topdir"

  for type in boot dtb modules; do
    TAR=$(find "$LOCAL_KDIR" -maxdepth 1 -name "${type}-*.tar.gz" | head -1)
    [ -z "$TAR" ] && [ "$type" = "dtb" ] && TAR=$(find "$LOCAL_KDIR" -maxdepth 1 -name "dtb-rockchip-*.tar.gz" | head -1)
    [ -n "$TAR" ] && tar xzf "$TAR" -C "$KERNEL_CACHE" && log "  ✓ 解压 $type: $(basename "$TAR")"
  done

  touch .ready
fi
KERNEL_TOPDIR=$(cat "$KERNEL_CACHE/.topdir" 2>/dev/null || echo "$KERNEL_CACHE/$SELECTED_VER")
log "  缓存: $KERNEL_CACHE"

# ============================================================
# 4. 复制骨架
# ============================================================
log "========== [4/7] 复制骨架 =========="
TARGET_DIR="$SDFUSE_DIR/$DIST_NAME"
rm -rf "$TARGET_DIR"
cp -a "$BASE_DIR" "$TARGET_DIR"
log "  已复制"

# ============================================================
# 5. 构造 kernel.img
# ============================================================
log "========== [5/7] 构造 kernel.img =========="

IMAGE_FILE=""
for pattern in "Image" "vmlinuz-*" "kernel*.img" "*.bin" "Image-*"; do
  IMAGE_FILE=$(find "$KERNEL_CACHE" -maxdepth 3 -type f -name "$pattern" 2>/dev/null | head -1)
  [ -n "$IMAGE_FILE" ] && break
done
[ -z "$IMAGE_FILE" ] && { err "找不到内核 Image"; find "$KERNEL_CACHE" -type f | head -20; exit 1; }

IMAGE_SIZE=$(stat -c%s "$IMAGE_FILE")
log "  内核文件: $(basename "$IMAGE_FILE") ($IMAGE_SIZE bytes)"
log "  类型: $(file -b "$IMAGE_FILE")"
log "  前 64 字节:"
xxd -l 64 "$IMAGE_FILE" | sed 's/^/    /'

MAGIC=$(xxd -l 4 -p "$IMAGE_FILE")
log "  magic: $MAGIC"

if [ "$MAGIC" = "4b524e4c" ]; then
  log "  >>> KRNL 格式"
  cp "$IMAGE_FILE" "$TARGET_DIR/kernel.img"

elif [ "$MAGIC" = "d00dfeed" ]; then
  log "  >>> FIT 格式"
  cp "$IMAGE_FILE" "$TARGET_DIR/kernel.img"

elif [ "$(xxd -l 2 -p "$IMAGE_FILE")" = "4d5a" ]; then
  log "  ⚠ PE 格式，仅修复 code0"
  python3 - "$IMAGE_FILE" "$WORK_DIR/patched.img" <<'PYEOF'
import sys, struct
data = bytearray(open(sys.argv[1], 'rb').read())
code0 = struct.unpack_from('<I', data, 0x00)[0]
data[0x00:0x04] = b'\x1f\x20\x03\xd5'
print(f"    ✓ code0: 0x{code0:08x} -> NOP")
open(sys.argv[2], 'wb').write(data)
PYEOF
  IMG_SIZE=$(stat -c%s "$WORK_DIR/patched.img")
  SIZE_HEX=$(printf '%08x' "$IMG_SIZE")
  SIZE_LE=$(echo "$SIZE_HEX" | sed 's/\(..\)\(..\)\(..\)\(..\)/\4\3\2\1/')
  printf 'KRNL' > "$TARGET_DIR/kernel.img"
  printf "$SIZE_LE" | xxd -r -p >> "$TARGET_DIR/kernel.img"
  cat "$WORK_DIR/patched.img" >> "$TARGET_DIR/kernel.img"
else
  log "  >>> 裸机 ARM64 Image"
  SIZE_HEX=$(printf '%08x' "$IMAGE_SIZE")
  SIZE_LE=$(echo "$SIZE_HEX" | sed 's/\(..\)\(..\)\(..\)\(..\)/\4\3\2\1/')
  printf 'KRNL' > "$TARGET_DIR/kernel.img"
  printf "$SIZE_LE" | xxd -r -p >> "$TARGET_DIR/kernel.img"
  cat "$IMAGE_FILE" >> "$TARGET_DIR/kernel.img"
fi

python3 - "$TARGET_DIR/kernel.img" <<'PYEOF'
import sys
data = open(sys.argv[1], 'rb').read(128)
assert data[0:4] == b'KRNL'
idx = data.find(b'ARM\x64')
print(f"    KRNL size: {int.from_bytes(data[4:8],'little')}")
print(f"    code0:     0x{int.from_bytes(data[8:12],'little'):08x}")
print(f"    magic@:    0x{idx:x}")
assert idx == 0x40
print("    ✓✓✓ KRNL OK")
PYEOF

# ============================================================
# 6. dtb + uInitrd
# ============================================================
log "========== [6/7] dtb + uInitrd =========="

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

log "  parameter.txt 保留原版"

# ============================================================
# 7. 生成镜像
# ============================================================
log "========== [7/7] 生成镜像 =========="
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

KERNEL_OFFSET=$((0x12000 * 512))
python3 - "$OUTPUT_IMG" "$KERNEL_OFFSET" <<'PYEOF'
import sys
img, off = sys.argv[1], int(sys.argv[2])
with open(img, 'rb') as f:
    f.seek(off); data = f.read(128)
assert data[0:4] == b'KRNL'
idx = data.find(b'ARM\x64')
assert idx == 0x40
print(f"    ✓ 最终镜像 magic@0x{idx:x}")
PYEOF

log "=========================================="
log "✓ 完成"
log "  内核: $SELECTED_VER"
log "  来源: $SELECTED_REPO / $SELECTED_RELEASE"
log "  输出: $OUTPUT_IMG"
log "=========================================="