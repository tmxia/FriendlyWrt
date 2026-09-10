#!/bin/bash
# quick-build.sh - 用已发布的 rootfs 包快速生成 flippy 固件
# 用法:
#   quick-build.sh <rootfs.tgz> <sdfuse_dir> <dist_name> <output_img>
#
# 参数:
#   rootfs.tgz   - rootfs-friendlywrt-*.tgz
#   sdfuse_dir   - scripts/sd-fuse 目录（含 mk-sd-image.sh）
#   dist_name    - friendlywrt24-docker 或 friendlywrt25-docker
#   output_img   - 输出 img 路径（含文件名）
set -euo pipefail

VERSION="2026-09-10-v1"
log() { echo -e "\033[0;32m[quick]\033[0m $*"; }
err() { echo -e "\033[0;31m[quick]\033[0m $*" >&2; }
log "quick-build.sh version: $VERSION"

ROOTFS_TGZ="$1"
SDFUSE_DIR="$2"
DIST_NAME="$3"
OUTPUT_IMG="$4"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WORK_DIR=$(mktemp -d /tmp/quick-build.XXXXXX)
trap "rm -rf $WORK_DIR" EXIT
log "工作目录: $WORK_DIR"

TARGET_DIR="$SDFUSE_DIR/$DIST_NAME"

# ========= 1. 准备 root 目录 =========
log "解压 rootfs tgz..."
mkdir -p "$WORK_DIR/rootfs"
tar xzf "$ROOTFS_TGZ" -C "$WORK_DIR/rootfs"

ROOT_DIR=""
for d in $(find "$WORK_DIR/rootfs" -maxdepth 3 -type d); do
  if [ -d "$d/bin" ] && [ -d "$d/etc" ] && [ -d "$d/usr" ] && [ -d "$d/lib" ]; then
    ROOT_DIR="$d"; break
  fi
done
[ -z "$ROOT_DIR" ] && { err "找不到 root 目录"; find "$WORK_DIR/rootfs" -maxdepth 3 -type d; exit 1; }
log "Root 目录: $ROOT_DIR"
log "  root 大小: $(du -sm "$ROOT_DIR" | awk '{print $1}') MiB"

# ========= 2. 替换 flippy modules =========
log "替换 root modules 为 flippy..."
bash "$SCRIPT_DIR/flippy-kernel.sh" apply-before-sdimg-root "$ROOT_DIR"

# ========= 3. 生成新的 rootfs.img（2 GiB） =========
log "生成 rootfs.img (2 GiB)..."
ROOTFS_IMG="$WORK_DIR/rootfs.img"
dd if=/dev/zero of="$ROOTFS_IMG" bs=1M count=2048 status=none
mkfs.ext4 -F -L rootfs -m 1 "$ROOTFS_IMG" >/dev/null 2>&1
mkdir -p "$WORK_DIR/rootfs_mnt"
sudo mount -o loop "$ROOTFS_IMG" "$WORK_DIR/rootfs_mnt"
sudo cp -a "$ROOT_DIR"/. "$WORK_DIR/rootfs_mnt/"
# 校验
USED_MB=$(df -m "$WORK_DIR/rootfs_mnt" | tail -1 | awk '{print $3}')
log "  rootfs 使用: ${USED_MB} MiB / 2048 MiB"
sudo umount "$WORK_DIR/rootfs_mnt"
log "  raw rootfs.img: $(stat -c%s "$ROOTFS_IMG") bytes"

# 转 Android sparse（节省镜像体积）
if command -v img2simg >/dev/null 2>&1; then
  log "  转 Android sparse..."
  img2simg "$ROOTFS_IMG" "$ROOTFS_IMG.sparse"
  mv "$ROOTFS_IMG.sparse" "$ROOTFS_IMG"
  log "  sparse: $(stat -c%s "$ROOTFS_IMG") bytes"
fi

# ========= 4. 从 rootfs tgz 生成完整骨架 =========
# 从 sd-fuse/prebuilt 或 repo 目录复制骨架
log "构建 sd-fuse 目录骨架..."
if [ ! -d "$TARGET_DIR" ]; then
  # 从 prebuilt 复制基础文件（uboot.img 等）
  if [ -d "$SDFUSE_DIR/prebuilt/$DIST_NAME" ]; then
    cp -a "$SDFUSE_DIR/prebuilt/$DIST_NAME" "$TARGET_DIR"
  else
    mkdir -p "$TARGET_DIR"
  fi
fi

# 需要的基本文件
need_files="idbloader.img uboot.img misc.img dtbo.img resource.img boot.img MiniLoaderAll.bin parameter.txt"
missing=0
for f in $need_files; do
  if [ ! -f "$TARGET_DIR/$f" ]; then
    log "  缺少 $f，尝试从 prebuilt 或其他位置复制..."
    for src in "$SDFUSE_DIR/prebuilt/$DIST_NAME/$f" "$SDFUSE_DIR/prebuilt/$DIST_NAME-rk3568/$f"; do
      if [ -f "$src" ]; then
        cp "$src" "$TARGET_DIR/$f"
        break
      fi
    done
    [ ! -f "$TARGET_DIR/$f" ] && { err "  无法找到 $f"; missing=1; }
  fi
done

if [ "$missing" = "1" ]; then
  err "缺少骨架文件，请检查 prebuilt 目录"
  find "$SDFUSE_DIR/prebuilt" -maxdepth 2 -type f | head -30
  exit 1
fi

# 用新生成的 rootfs.img 覆盖
cp -f "$ROOTFS_IMG" "$TARGET_DIR/rootfs.img"
log "  rootfs.img 已替换"

# ========= 5. 替换 kernel.img 为 flippy =========
log "替换 kernel.img + dtb + parameter.txt..."
bash "$SCRIPT_DIR/flippy-kernel.sh" apply "$TARGET_DIR"

log "目录内容:"
ls -la "$TARGET_DIR/"

# ========= 6. 生成最终镜像 =========
log "生成最终镜像..."
cd "$SDFUSE_DIR"
chmod +x mk-sd-image.sh
rm -f out/*.img
set +e
yes | ./mk-sd-image.sh "$DIST_NAME" > /tmp/mk-sd.log 2>&1
MK_EXIT=$?
set -e
echo "mk-sd-image.sh exit code: $MK_EXIT"
tail -40 /tmp/mk-sd.log

FOUND_IMG=$(find out -maxdepth 1 -name "*.img" -print -quit)
[ -z "$FOUND_IMG" ] && { err "未生成镜像"; ls -la out/; exit 1; }
mv "$FOUND_IMG" "$OUTPUT_IMG"
log "输出: $OUTPUT_IMG ($(stat -c%s "$OUTPUT_IMG") bytes)"

# ========= 7. 验证 =========
log "验证镜像..."
bash "$SCRIPT_DIR/flippy-kernel.sh" verify "$OUTPUT_IMG"

log "✓ 完成 (version $VERSION)"