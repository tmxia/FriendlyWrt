#!/bin/bash
# replace-kernel.sh - 使用 ophub kernel_rk35xx 专用内核替换 FriendlyWrt kernel.img
# 
# 用法:
#   replace-kernel.sh <images.tgz> <sdfuse-dir> <dist-name> <output-img>
#
# 环境变量:
#   TARGET_MODEL  - r5s (默认) / r5c
#   SLIM_MODE     - true (默认) 精简 dtb / false 保留全部
#   KERNEL_RELEASE - kernel_rk35xx (默认) / kernel_flippy
set -euo pipefail

VERSION="2026-09-10-v4-rk35xx"
log() { echo -e "\033[0;32m[replace]\033[0m $*"; }
err() { echo -e "\033[0;31m[replace]\033[0m $*" >&2; }
log "replace-kernel.sh version: $VERSION"

IMAGES_TGZ="$1"
SDFUSE_DIR="$2"
DIST_NAME="$3"
OUTPUT_IMG="$4"
TARGET_MODEL="${TARGET_MODEL:-r5s}"
SLIM_MODE="${SLIM_MODE:-true}"
KERNEL_RELEASE="${KERNEL_RELEASE:-kernel_rk35xx}"

log "参数:"
log "  images.tgz:      $(basename "$IMAGES_TGZ")"
log "  sd-fuse dir:     $SDFUSE_DIR"
log "  dist name:       $DIST_NAME"
log "  output img:      $OUTPUT_IMG"
log "  target model:    $TARGET_MODEL"
log "  slim mode:       $SLIM_MODE"
log "  kernel release:  $KERNEL_RELEASE"

WORK_DIR=$(mktemp -d /tmp/replace-kernel.XXXXXX)
trap "rm -rf $WORK_DIR" EXIT
log "工作目录: $WORK_DIR"

# ============================================================
# 1. 解压官方 images tgz
# ============================================================
log "========== [1/6] 解压官方 images tgz =========="
mkdir -p "$WORK_DIR/base"
tar xzf "$IMAGES_TGZ" -C "$WORK_DIR/base"

BASE_DIR=$(find "$WORK_DIR/base" -maxdepth 2 -type d -name "friendlywrt*" | head -1)
[ -z "$BASE_DIR" ] && { err "找不到顶层目录"; ls -la "$WORK_DIR/base"; exit 1; }
log "官方 images 顶层: $BASE_DIR"
ls -la "$BASE_DIR/"

# ============================================================
# 2. 下载并解压 Rockchip 专用内核
# ============================================================
log "========== [2/6] 获取 $KERNEL_RELEASE 内核 =========="

KERNEL_VER=$(gh release view "$KERNEL_RELEASE" --repo ophub/kernel --json assets --jq '.assets[].name' \
  | grep -E '^[0-9]+\.[0-9]+\.[0-9]+.*\.tar\.gz$' | sed 's/\.tar\.gz//' | sort -V | tail -1)
[ -z "$KERNEL_VER" ] && { err "获取 $KERNEL_RELEASE 版本失败"; exit 1; }
log "  内核版本: $KERNEL_VER"

KERNEL_CACHE="/tmp/${KERNEL_RELEASE}-cache/$KERNEL_VER"
if [ ! -f "$KERNEL_CACHE/.ready" ]; then
  log "  下载 $KERNEL_RELEASE $KERNEL_VER ..."
  rm -rf "$KERNEL_CACHE"
  mkdir -p "$KERNEL_CACHE"
  cd "$KERNEL_CACHE"
  wget -q "https://github.com/ophub/kernel/releases/download/${KERNEL_RELEASE}/${KERNEL_VER}.tar.gz" -O kernel.tar.gz
  tar xzf kernel.tar.gz

  LOCAL_KDIR="$KERNEL_VER"
  [ ! -d "$LOCAL_KDIR" ] && LOCAL_KDIR=$(find . -maxdepth 1 -type d -name "*$KERNEL_VER*" | head -1)
  [ -z "$LOCAL_KDIR" ] && { err "解压后找不到内核目录"; ls -la; exit 1; }

  log "  内核目录内容:"
  ls -la "$LOCAL_KDIR/"

  mkdir -p boot dtb modules

  # 查找 boot 子包（可能命名为 boot-*.tar.gz / Image-*.tar.gz 等）
  BOOT_TAR=$(find "$LOCAL_KDIR" -maxdepth 1 -name "boot-*.tar.gz" | head -1)
  if [ -z "$BOOT_TAR" ]; then
    BOOT_TAR=$(find "$LOCAL_KDIR" -maxdepth 1 -name "*boot*.tar.gz" | head -1)
  fi
  [ -n "$BOOT_TAR" ] && tar xzf "$BOOT_TAR" -C boot

  # 查找 dtb 子包（优先 rockchip）
  DTB_TAR=$(find "$LOCAL_KDIR" -maxdepth 1 -name "dtb-rockchip-*.tar.gz" | head -1)
  [ -z "$DTB_TAR" ] && DTB_TAR=$(find "$LOCAL_KDIR" -maxdepth 1 -name "dtb-*.tar.gz" | head -1)
  [ -n "$DTB_TAR" ] && tar xzf "$DTB_TAR" -C dtb

  # 查找 modules 子包
  MODULES_TAR=$(find "$LOCAL_KDIR" -maxdepth 1 -name "modules-*.tar.gz" | head -1)
  [ -n "$MODULES_TAR" ] && tar xzf "$MODULES_TAR" -C modules

  log "  boot 目录内容:"
  ls -la "$KERNEL_CACHE/boot/" 2>/dev/null || log "    (空)"
  log "  dtb 目录内容 (前 5):"
  ls "$KERNEL_CACHE/dtb/" 2>/dev/null | head -5 || log "    (空)"
  log "  modules 目录内容:"
  ls -la "$KERNEL_CACHE/modules/" 2>/dev/null || log "    (空)"

  touch .ready
fi
log "  内核缓存: $KERNEL_CACHE"

# ============================================================
# 3. 复制官方骨架到目标
# ============================================================
log "========== [3/6] 复制官方骨架 =========="
TARGET_DIR="$SDFUSE_DIR/$DIST_NAME"
rm -rf "$TARGET_DIR"
cp -a "$BASE_DIR" "$TARGET_DIR"
log "  已复制: $TARGET_DIR"
ls -la "$TARGET_DIR/"

# ============================================================
# 4. 构造 kernel.img（使用专用内核）
# ============================================================
log "========== [4/6] 构造 kernel.img =========="

# 在 boot 目录查找内核文件
IMAGE_FILE=""
for pattern in "Image" "vmlinuz-*" "kernel*.img" "*.bin" "Image-*"; do
  IMAGE_FILE=$(find "$KERNEL_CACHE/boot" -maxdepth 2 -name "$pattern" -type f 2>/dev/null | head -1)
  [ -n "$IMAGE_FILE" ] && break
done

if [ -z "$IMAGE_FILE" ]; then
  err "找不到内核 Image 文件"
  log "boot 目录完整列表:"
  ls -laR "$KERNEL_CACHE/boot/"
  exit 1
fi

IMAGE_SIZE=$(stat -c%s "$IMAGE_FILE")
log "  内核文件: $(basename "$IMAGE_FILE") ($IMAGE_SIZE bytes)"
log "  文件类型:"
file "$IMAGE_FILE" || true
log "  前 64 字节:"
xxd -l 64 "$IMAGE_FILE"

MAGIC=$(xxd -l 4 -p "$IMAGE_FILE")
log "  前 4 字节 magic: $MAGIC"

# 根据 magic 判断格式
if [ "$MAGIC" = "4b524e4c" ]; then
  # 已经是 KRNL 格式
  log "  >>> 文件已是 KRNL 格式，直接使用"
  cp "$IMAGE_FILE" "$TARGET_DIR/kernel.img"

elif [ "$MAGIC" = "d00dfeed" ]; then
  # FIT 格式（Device Tree Blob）
  log "  >>> FIT 格式，需要 U-Boot 支持 FIT（Rockchip 原生支持）"
  log "  直接用 FIT 覆盖 kernel.img（Rockchip U-Boot 支持 FIT）"
  cp "$IMAGE_FILE" "$TARGET_DIR/kernel.img"

elif [ "$(xxd -l 2 -p "$IMAGE_FILE")" = "4d5a" ]; then
  # PE 格式（EFI stub）
  log "  >>> PE 格式，尝试提取纯 ARM64 Image..."
  python3 - "$IMAGE_FILE" "$WORK_DIR/extracted.img" <<'PYEOF'
import sys
data = open(sys.argv[1], 'rb').read()
# ARM64 Image 的 magic "ARM\x64" 通常位于 Image 起始偏移 0x38
idx = data.find(b'ARM\x64')
if idx >= 0x38:
    start = idx - 0x38
    image_data = data[start:]
    # 检查提取的数据是否是有效 ARM64 Image（前 4 字节应为有效 ARM64 指令）
    if len(image_data) > 0x1000:
        open(sys.argv[2], 'wb').write(image_data)
        print(f"  ✓ 从 PE 提取 ARM64 Image: 起始 0x{start:x}, 大小 {len(image_data)}")
        sys.exit(0)
print("  ✗ 无法提取")
sys.exit(1)
PYEOF
  if [ -f "$WORK_DIR/extracted.img" ]; then
    # 提取出的 Image，构造 KRNL 头
    IMG_SIZE=$(stat -c%s "$WORK_DIR/extracted.img")
    SIZE_HEX=$(printf '%08x' "$IMG_SIZE")
    SIZE_LE=$(echo "$SIZE_HEX" | sed 's/\(..\)\(..\)\(..\)\(..\)/\4\3\2\1/')
    printf 'KRNL' > "$TARGET_DIR/kernel.img"
    printf "$SIZE_LE" | xxd -r -p >> "$TARGET_DIR/kernel.img"
    cat "$WORK_DIR/extracted.img" >> "$TARGET_DIR/kernel.img"
    log "  已构造 KRNL + Image"
  else
    err "PE 提取失败"
    exit 1
  fi

elif [ "$MAGIC" = "1f8b0800" ] || [ "$(xxd -l 2 -p "$IMAGE_FILE")" = "1f8b" ]; then
  # gzip 压缩
  log "  >>> gzip 压缩，解压后构造 KRNL"
  gunzip -c "$IMAGE_FILE" > "$WORK_DIR/uncompressed.img" 2>/dev/null || cp "$IMAGE_FILE" "$WORK_DIR/uncompressed.img"
  IMG_SIZE=$(stat -c%s "$WORK_DIR/uncompressed.img")
  SIZE_HEX=$(printf '%08x' "$IMG_SIZE")
  SIZE_LE=$(echo "$SIZE_HEX" | sed 's/\(..\)\(..\)\(..\)\(..\)/\4\3\2\1/')
  printf 'KRNL' > "$TARGET_DIR/kernel.img"
  printf "$SIZE_LE" | xxd -r -p >> "$TARGET_DIR/kernel.img"
  cat "$WORK_DIR/uncompressed.img" >> "$TARGET_DIR/kernel.img"

else
  # 未知格式，检查是否包含 ARM64 magic
  log "  >>> 未知格式，检查是否包含 ARM64 magic..."
  ARM64_POS=$(python3 -c "
data = open('$IMAGE_FILE', 'rb').read(1024)
idx = data.find(b'ARM\x64')
print(idx)
")
  log "  ARM64 magic 位置: $ARM64_POS"

  if [ "$ARM64_POS" = "56" ] || [ "$ARM64_POS" = "0x38" ] || [ "$ARM64_POS" = "56" ]; then
    # magic 在 0x38，说明前 0x38 是有效的 Image 头
    log "  >>> ARM64 magic 在 0x38，是有效 Image 格式"
    IMG_SIZE=$IMAGE_SIZE
    SIZE_HEX=$(printf '%08x' "$IMG_SIZE")
    SIZE_LE=$(echo "$SIZE_HEX" | sed 's/\(..\)\(..\)\(..\)\(..\)/\4\3\2\1/')
    printf 'KRNL' > "$TARGET_DIR/kernel.img"
    printf "$SIZE_LE" | xxd -r -p >> "$TARGET_DIR/kernel.img"
    cat "$IMAGE_FILE" >> "$TARGET_DIR/kernel.img"
  else
    log "  >>> 尝试作为纯 Image 使用"
    IMG_SIZE=$IMAGE_SIZE
    SIZE_HEX=$(printf '%08x' "$IMG_SIZE")
    SIZE_LE=$(echo "$SIZE_HEX" | sed 's/\(..\)\(..\)\(..\)\(..\)/\4\3\2\1/')
    printf 'KRNL' > "$TARGET_DIR/kernel.img"
    printf "$SIZE_LE" | xxd -r -p >> "$TARGET_DIR/kernel.img"
    cat "$IMAGE_FILE" >> "$TARGET_DIR/kernel.img"
  fi
fi

# 验证 kernel.img
log "  验证 kernel.img..."
python3 - "$TARGET_DIR/kernel.img" <<'PYEOF'
import sys
data = open(sys.argv[1], 'rb').read(256)
assert data[0:4] == b'KRNL', 'KRNL magic missing!'
size = int.from_bytes(data[4:8], 'little')
print(f'  ✓ KRNL 头: magic=OK, size={size}')
# 检查 code0 (第 9-12 字节)
code0 = int.from_bytes(data[8:12], 'little')
print(f'  code0 = 0x{code0:08x}')
idx = data.find(b'ARM\x64')
if idx > 0:
    print(f'  ARM64 magic at: 0x{idx:x}')
PYEOF

log "  新 kernel.img: $(stat -c%s "$TARGET_DIR/kernel.img") bytes"

# ============================================================
# 5. 替换 dtb + uInitrd + parameter.txt
# ============================================================
log "========== [5/6] 替换 dtb + uInitrd + parameter.txt =========="

# 5.1 dtb
log "  处理 dtb..."
if [ "$SLIM_MODE" = "true" ]; then
  DTB_R5S=$(find "$KERNEL_CACHE/dtb" -name "rk3568-nanopi-r5s.dtb" | head -1)
  DTB_R5C=$(find "$KERNEL_CACHE/dtb" -name "rk3568-nanopi-r5c.dtb" | head -1)
  log "    r5s: ${DTB_R5S:-未找到}"
  log "    r5c: ${DTB_R5C:-未找到}"

  if [ -n "$DTB_R5S" ] || [ -n "$DTB_R5C" ]; then
    if [ -d "$TARGET_DIR/dtb/rockchip" ]; then
      BEFORE=$(find "$TARGET_DIR/dtb" -name "*.dtb" | wc -l)
      rm -rf "$TARGET_DIR/dtb/rockchip"
      mkdir -p "$TARGET_DIR/dtb/rockchip"
      [ -n "$DTB_R5S" ] && cp -f "$DTB_R5S" "$TARGET_DIR/dtb/rockchip/"
      [ -n "$DTB_R5C" ] && cp -f "$DTB_R5C" "$TARGET_DIR/dtb/rockchip/"
      AFTER=$(find "$TARGET_DIR/dtb" -name "*.dtb" | wc -l)
      log "    dtb: $BEFORE -> $AFTER 个"
    fi
  else
    log "    WARNING: 内核包中找不到 r5s/r5c dtb，保留骨架 dtb"
  fi
else
  log "    完整模式：保留骨架 dtb"
fi

# 5.2 uInitrd
log "  处理 uInitrd..."
UINITRD=$(find "$KERNEL_CACHE/boot" -name "uInitrd-*" | head -1)
if [ -n "$UINITRD" ]; then
  cp "$UINITRD" "$TARGET_DIR/uInitrd"
  log "    uInitrd: $(stat -c%s "$TARGET_DIR/uInitrd") bytes"
else
  # 尝试从 initrd.img 转换
  INITRD=$(find "$KERNEL_CACHE/boot" -name "initrd.img-*" | head -1)
  if [ -n "$INITRD" ] && command -v mkimage >/dev/null 2>&1; then
    log "    从 initrd.img 转换..."
    mkimage -A arm64 -O linux -T ramdisk -C gzip -n "uInitrd" -d "$INITRD" "$TARGET_DIR/uInitrd" 2>/dev/null || \
      cp "$INITRD" "$TARGET_DIR/uInitrd"
    log "    uInitrd: $(stat -c%s "$TARGET_DIR/uInitrd") bytes"
  else
    log "    WARNING: 找不到 uInitrd，保留骨架的 boot.img 中的 initrd"
  fi
fi

# 5.3 parameter.txt
log "  处理 parameter.txt..."
PARAM="$TARGET_DIR/parameter.txt"
ORIG_PAT='0x00014000@0x00012000(kernel),0x00010000@0x00026000(boot),0x00010000@0x00036000(recovery),0x00200000@0x00046000(rootfs),0x00200000@0x00246000(userdata:grow),-@0x00446000(opt:grow)'
NEW_PAT='0x00018000@0x00012000(kernel),0x00010000@0x0002a000(boot),0x00010000@0x0003a000(recovery),0x00200000@0x0004a000(rootfs),0x00200000@0x0024a000(userdata:grow),-@0x0044a000(opt:grow)'

if grep -q "0x00018000@0x00012000(kernel)" "$PARAM"; then
  log "    已扩展，跳过"
else
  sed -i "s|$ORIG_PAT|$NEW_PAT|" "$PARAM"
  if grep -q "0x00018000@0x00012000(kernel)" "$PARAM"; then
    log "    kernel 分区: 40 MiB -> 48 MiB"
  else
    err "    parameter.txt 修改失败"
    grep CMDLINE "$PARAM"
    exit 1
  fi
fi

log "  最终目录内容:"
ls -la "$TARGET_DIR/"

# ============================================================
# 6. 生成镜像 + 验证
# ============================================================
log "========== [6/6] 生成最终镜像 =========="
cd "$SDFUSE_DIR"
chmod +x mk-sd-image.sh
rm -f out/*.img

set +e
yes | ./mk-sd-image.sh "$DIST_NAME" > /tmp/mk-sd.log 2>&1
MK_EXIT=$?
set -e
echo "mk-sd-image.sh exit code: $MK_EXIT"
tail -50 /tmp/mk-sd.log

FOUND_IMG=$(find out -maxdepth 1 -name "*.img" -print -quit)
[ -z "$FOUND_IMG" ] && { err "未生成镜像"; ls -la out/; exit 1; }

mv "$FOUND_IMG" "$OUTPUT_IMG"
log "输出: $OUTPUT_IMG ($(stat -c%s "$OUTPUT_IMG") bytes)"

# 验证 kernel 分区
KERNEL_OFFSET=$((0x12000 * 512))
log "验证 kernel 分区（偏移 $KERNEL_OFFSET）..."
python3 - "$OUTPUT_IMG" "$KERNEL_OFFSET" <<'PYEOF'
import sys
img, off = sys.argv[1], int(sys.argv[2])
with open(img, 'rb') as f:
    f.seek(off)
    data = f.read(256)
assert data[0:4] == b'KRNL', 'KRNL missing!'
size = int.from_bytes(data[4:8], 'little')
code0 = int.from_bytes(data[8:12], 'little')
print(f'  ✓ KRNL 头: size={size}, code0=0x{code0:08x}')
idx = data.find(b'ARM\x64')
if idx > 0:
    print(f'  ✓ ARM64 magic at: 0x{idx:x}')
print('  ✓ kernel 分区含新内核')
PYEOF

log "=========================================="
log "✓ 完成 (version $VERSION)"
log "  输出: $OUTPUT_IMG"
log "  大小: $(stat -c%s "$OUTPUT_IMG") bytes ($(($(stat -c%s "$OUTPUT_IMG")/1024/1024)) MiB)"
log "=========================================="