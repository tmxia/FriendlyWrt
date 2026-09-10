#!/bin/bash
# quick-build.sh - 用已发布的 rootfs 包快速生成 flippy 固件
set -euo pipefail

VERSION="2026-09-10-v2"
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

log "解压后结构（前 3 层）:"
find "$WORK_DIR/rootfs" -maxdepth 3 -type d | head -30

# 多层健壮查找 root 目录
ROOT_DIR=""

# 方法1: 优先找名为 root-rockchip 的目录
ROOT_DIR=$(find "$WORK_DIR/rootfs" -maxdepth 10 -type d -name "root-rockchip" 2>/dev/null | head -1)
log "方法1 (root-rockchip): ${ROOT_DIR:-未找到}"

# 方法2: 找包含 etc/openwrt_release 的目录
if [ -z "$ROOT_DIR" ] || [ ! -d "$ROOT_DIR/bin" ]; then
  local_release=$(find "$WORK_DIR/rootfs" -maxdepth 10 -type f \( -name "openwrt_release" -o -name "os-release" \) 2>/dev/null | head -1)
  if [ -n "$local_release" ]; then
    ROOT_DIR=$(dirname "$(dirname "$local_release")")
  fi
  log "方法2 (openwrt_release): ${ROOT_DIR:-未找到}"
fi

# 方法3: 找同时有 bin/sbin/etc/usr/lib 且没有 build_dir 的目录
if [ -z "$ROOT_DIR" ] || [ ! -d "$ROOT_DIR/bin" ]; then
  while IFS= read -r d; do
    if [ -d "$d/bin" ] && [ -d "$d/etc" ] && [ -d "$d/usr" ] && \
       [ -d "$d/lib" ] && [ -d "$d/sbin" ] && [ ! -d "$d/build_dir" ]; then
      ROOT_DIR="$d"
      break
    fi
  done < <(find "$WORK_DIR/rootfs" -maxdepth 10 -type d | sort -r)
  log "方法3 (特征目录): ${ROOT_DIR:-未找到}"
fi

if [ -z "$ROOT_DIR" ] || [ ! -d "$ROOT_DIR/bin" ] || [ ! -d "$ROOT_DIR/etc" ]; then
  err "找不到有效 root 目录"
  err "完整目录树:"
  find "$WORK_DIR/rootfs" -maxdepth 6 -type d | head -100
  exit 1
fi

log "✓ Root 目录: $ROOT_DIR"
log "  内容预览:"
ls "$ROOT_DIR/" | head -20
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

log "  复制 root 内容到 rootfs.img..."
sudo cp -a "$ROOT_DIR"/. "$WORK_DIR/rootfs_mnt/"

# 校验
USED_MB=$(df -m "$WORK_DIR/rootfs_mnt" | tail -1 | awk '{print $3}')
AVAIL_MB=$(df -m "$WORK_DIR/rootfs_mnt" | tail -1 | awk '{print $4}')
log "  rootfs 使用: ${USED_MB} MiB / 2048 MiB (剩余 ${AVAIL_MB} MiB)"

sudo umount "$WORK_DIR/rootfs_mnt"
log "  raw rootfs.img: $(stat -c%s "$ROOTFS_IMG") bytes"

# 转 Android sparse
if command -v img2simg >/dev/null 2>&1; then
  log "  转 Android sparse..."
  img2simg "$ROOTFS_IMG" "$ROOTFS_IMG.sparse"
  mv "$ROOTFS_IMG.sparse" "$ROOTFS_IMG"
  log "  sparse: $(stat -c%s "$ROOTFS_IMG") bytes"
fi

# ========= 4. 构建 sd-fuse 目录骨架 =========
log "构建 sd-fuse 目录骨架..."
if [ -d "$SDFUSE_DIR/prebuilt/$DIST_NAME" ]; then
  log "  从 prebuilt/$DIST_NAME 复制"
  rm -rf "$TARGET_DIR"
  cp -a "$SDFUSE_DIR/prebuilt/$DIST_NAME" "$TARGET_DIR"
else
  log "  没有 prebuilt/$DIST_NAME，检查 prebuilt/"
  ls -la "$SDFUSE_DIR/prebuilt/" || true
  mkdir -p "$TARGET_DIR"
fi

# 检查必需文件
need_files="idbloader.img uboot.img misc.img dtbo.img resource.img boot.img MiniLoaderAll.bin parameter.txt"
missing_files=""
for f in $need_files; do
  if [ ! -f "$TARGET_DIR/$f" ]; then
    missing_files="$missing_files $f"
    log "  缺少 $f"
  fi
done

if [ -n "$missing_files" ]; then
  err "缺少骨架文件: $missing_files"
  err "尝试从 sd-fuse 其他地方查找..."
  find "$SDFUSE_DIR" -maxdepth 3 -name "uboot.img" -o -maxdepth 3 -name "idbloader.img" 2>/dev/null | head -10
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
tail -50 /tmp/mk-sd.log

FOUND_IMG=$(find out -maxdepth 1 -name "*.img" -print -quit)
[ -z "$FOUND_IMG" ] && { err "未生成镜像"; ls -la out/; exit 1; }
mv "$FOUND_IMG" "$OUTPUT_IMG"
log "输出: $OUTPUT_IMG ($(stat -c%s "$OUTPUT_IMG") bytes)"

# ========= 7. 验证 =========
log "验证镜像..."
bash "$SCRIPT_DIR/flippy-kernel.sh" verify "$OUTPUT_IMG"

log "✓ 完成 (version $VERSION)"