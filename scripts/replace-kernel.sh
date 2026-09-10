#!/bin/bash
# replace-kernel.sh - 基于官方 images.tgz 快速生成 flippy 内核固件
# 只替换: kernel.img / dtb(精简) / modules(精简) / uInitrd / parameter.txt
#
# 用法:
#   replace-kernel.sh <images.tgz> <sdfuse-dir> <dist-name> <output-img>
#
# 环境变量:
#   TARGET_MODEL  - r5s (默认) 或 r5c
#   SLIM_MODE     - true (默认) 精简 dtb 和 modules / false 保留全部
set -euo pipefail

VERSION="2026-09-10-v2"
log() { echo -e "\033[0;32m[replace]\033[0m $*"; }
err() { echo -e "\033[0;31m[replace]\033[0m $*" >&2; }
log "replace-kernel.sh version: $VERSION"

IMAGES_TGZ="$1"
SDFUSE_DIR="$2"
DIST_NAME="$3"
OUTPUT_IMG="$4"
TARGET_MODEL="${TARGET_MODEL:-r5s}"
SLIM_MODE="${SLIM_MODE:-true}"

log "参数:"
log "  images.tgz:    $IMAGES_TGZ"
log "  sd-fuse dir:   $SDFUSE_DIR"
log "  dist name:     $DIST_NAME"
log "  output img:    $OUTPUT_IMG"
log "  target model:  $TARGET_MODEL"
log "  slim mode:     $SLIM_MODE"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WORK_DIR=$(mktemp -d /tmp/replace-kernel.XXXXXX)
trap "rm -rf $WORK_DIR" EXIT
log "工作目录: $WORK_DIR"

# ============================================================
# 1. 解压官方 images tgz
# ============================================================
log "========== [1/9] 解压官方 images tgz =========="
mkdir -p "$WORK_DIR/base"
tar xzf "$IMAGES_TGZ" -C "$WORK_DIR/base"

BASE_DIR=$(find "$WORK_DIR/base" -maxdepth 2 -type d -name "friendlywrt*" | head -1)
[ -z "$BASE_DIR" ] && { err "找不到顶层目录"; ls -la "$WORK_DIR/base"; exit 1; }
log "官方 images 顶层: $BASE_DIR"
ls -la "$BASE_DIR/"

# ============================================================
# 2. 下载并解压 flippy 内核
# ============================================================
log "========== [2/9] 获取 flippy 内核 =========="
FLIPPY_VER=$(gh release view kernel_flippy --repo ophub/kernel --json assets --jq '.assets[].name' \
  | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.tar\.gz$' | sed 's/\.tar\.gz//' | sort -V | tail -1)
[ -z "$FLIPPY_VER" ] && { err "获取 flippy 版本失败"; exit 1; }
log "  flippy 版本: $FLIPPY_VER"

FLIPPY_CACHE="/tmp/flippy-cache/$FLIPPY_VER"
if [ ! -f "$FLIPPY_CACHE/.ready" ]; then
  log "  下载 flippy $FLIPPY_VER..."
  rm -rf "$FLIPPY_CACHE"
  mkdir -p "$FLIPPY_CACHE"
  cd "$FLIPPY_CACHE"
  wget -q "https://github.com/ophub/kernel/releases/download/kernel_flippy/${FLIPPY_VER}.tar.gz" -O flippy.tar.gz
  tar xzf flippy.tar.gz
  local_kdir="$FLIPPY_VER"
  [ ! -d "$local_kdir" ] && local_kdir=$(find . -maxdepth 1 -type d -name "*$FLIPPY_VER*" | head -1)
  mkdir -p boot dtb modules
  tar xzf "$(find "$local_kdir" -name 'boot-*.tar.gz' | head -1)" -C boot
  tar xzf "$(find "$local_kdir" -name 'dtb-rockchip-*.tar.gz' | head -1)" -C dtb
  tar xzf "$(find "$local_kdir" -name 'modules-*.tar.gz' | head -1)" -C modules
  touch .ready
fi
log "  flippy 缓存: $FLIPPY_CACHE"
log "  boot 内容:"
ls -la "$FLIPPY_CACHE/boot/" | head -10

# ============================================================
# 3. 复制官方骨架到目标目录
# ============================================================
log "========== [3/9] 复制官方骨架 =========="
TARGET_DIR="$SDFUSE_DIR/$DIST_NAME"
rm -rf "$TARGET_DIR"
cp -a "$BASE_DIR" "$TARGET_DIR"
log "  已复制到: $TARGET_DIR"

# ============================================================
# 4. 替换 kernel.img（含 NOP 修复）
# ============================================================
log "========== [4/9] 构造 flippy kernel.img =========="
VMLINUZ=$(find "$FLIPPY_CACHE/boot" -name "vmlinuz-*" | head -1)
[ -z "$VMLINUZ" ] && { err "找不到 vmlinuz"; exit 1; }
VMLINUZ_SIZE=$(stat -c%s "$VMLINUZ")
log "  flippy vmlinuz: $(basename "$VMLINUZ") ($VMLINUZ_SIZE bytes)"
log "  原 kernel.img: $(stat -c%s "$TARGET_DIR/kernel.img") bytes"

# 关键: flippy vmlinuz 的 code0 = 0xfa405a4d (MZ 魔数, 非法 ARM64 指令)
# 替换为 NOP (0xd503201f), 让 CPU 执行 NOP 后跳到 code1 的合法分支
echo "1f2003d5" | xxd -r -p > "$WORK_DIR/vmlinuz_patched"
tail -c +5 "$VMLINUZ" >> "$WORK_DIR/vmlinuz_patched"

# 构造 KRNL + size(LE) + patched vmlinuz
SIZE_HEX=$(printf '%08x' "$VMLINUZ_SIZE")
SIZE_LE=$(echo "$SIZE_HEX" | sed 's/\(..\)\(..\)\(..\)\(..\)/\4\3\2\1/')
printf 'KRNL' > "$TARGET_DIR/kernel.img"
printf "$SIZE_LE" | xxd -r -p >> "$TARGET_DIR/kernel.img"
cat "$WORK_DIR/vmlinuz_patched" >> "$TARGET_DIR/kernel.img"

# 断言
python3 - "$TARGET_DIR/kernel.img" <<'PYEOF'
import sys
data = open(sys.argv[1], 'rb').read(256)
assert data[0:4] == b'KRNL', 'KRNL missing'
assert int.from_bytes(data[8:12], 'little') == 0xd503201f, 'code0 not NOP'
assert data.find(b'ARM\x64') == 0x40, 'magic not at 0x40'
print('  ✓ kernel.img: KRNL + NOP + ARM64 magic@0x40')
PYEOF
log "  新 kernel.img: $(stat -c%s "$TARGET_DIR/kernel.img") bytes"

# ============================================================
# 5. 精简 dtb（只保留目标机型）
# ============================================================
log "========== [5/9] 处理 dtb =========="
if [ -d "$TARGET_DIR/dtb/rockchip" ]; then
  BEFORE=$(find "$TARGET_DIR/dtb" -type f -name "*.dtb" 2>/dev/null | wc -l)
  log "  骨架中 dtb: $BEFORE 个"
  if [ "$SLIM_MODE" = "true" ]; then
    log "  精简模式：删除非 RK3568 相关 dtb..."
    find "$TARGET_DIR/dtb" -type f -name "*.dtb" | while read -r f; do
      base=$(basename "$f")
      # 保留: rk3568-* / rk3566-* / nanopi r5s r5c
      if ! echo "$base" | grep -qE "^(rk3568|rk3566)"; then
        rm -f "$f"
      fi
    done
    AFTER=$(find "$TARGET_DIR/dtb" -type f -name "*.dtb" 2>/dev/null | wc -l)
    log "  精简后: $AFTER 个"
  fi
fi

# 用 flippy 的 dtb 覆盖目标机型的 dtb（保证内核兼容）
FLIPPY_DTB_R5S=$(find "$FLIPPY_CACHE/dtb" -name "rk3568-nanopi-r5s.dtb" | head -1)
FLIPPY_DTB_R5C=$(find "$FLIPPY_CACHE/dtb" -name "rk3568-nanopi-r5c.dtb" | head -1)
log "  flippy r5s dtb: ${FLIPPY_DTB_R5S:-无}"
log "  flippy r5c dtb: ${FLIPPY_DTB_R5C:-无}"

if [ "$SLIM_MODE" = "true" ]; then
  # 精简模式：只保留 r5s 和 r5c
  rm -rf "$TARGET_DIR/dtb/rockchip"
  mkdir -p "$TARGET_DIR/dtb/rockchip"
  [ -n "$FLIPPY_DTB_R5S" ] && cp -f "$FLIPPY_DTB_R5S" "$TARGET_DIR/dtb/rockchip/"
  [ -n "$FLIPPY_DTB_R5C" ] && cp -f "$FLIPPY_DTB_R5C" "$TARGET_DIR/dtb/rockchip/"
  log "  精简后 dtb 只保留:"
  ls -la "$TARGET_DIR/dtb/rockchip/"
else
  # 完整模式：用 flippy 的 dtb 覆盖
  [ -n "$FLIPPY_DTB_R5S" ] && cp -f "$FLIPPY_DTB_R5S" "$TARGET_DIR/dtb/rockchip/"
  [ -n "$FLIPPY_DTB_R5C" ] && cp -f "$FLIPPY_DTB_R5C" "$TARGET_DIR/dtb/rockchip/"
fi

# ============================================================
# 6. 处理 rootfs.img：替换 modules
# ============================================================
log "========== [6/9] 处理 rootfs.img =========="
ROOTFS_IMG="$TARGET_DIR/rootfs.img"
ROOTFS_RAW="$WORK_DIR/rootfs_raw.img"

log "  转换 rootfs.img -> raw..."
simg2img "$ROOTFS_IMG" "$ROOTFS_RAW" 2>/dev/null || cp "$ROOTFS_IMG" "$ROOTFS_RAW"
ORIG_MB=$(($(stat -c%s "$ROOTFS_RAW") / 1024 / 1024))
log "  原 raw 大小: ${ORIG_MB} MiB"

# 准备 modules
MODULES_SRC=$(find "$FLIPPY_CACHE/modules" -maxdepth 1 -mindepth 1 -type d | head -1)
MODULES_NAME=$(basename "$MODULES_SRC")
MODULES_MB=$(du -sm "$MODULES_SRC" | awk '{print $1}')
log "  flippy modules: $MODULES_NAME (${MODULES_MB} MiB)"

# 精简 modules
if [ "$SLIM_MODE" = "true" ]; then
  log "  精简 modules..."
  mkdir -p "$WORK_DIR/modules"
  cp -a "$MODULES_SRC" "$WORK_DIR/modules/"
  SLIM_MOD="$WORK_DIR/modules/$MODULES_NAME"

  # 删除非 rockchip 平台的驱动模块
  if [ -d "$SLIM_MOD/kernel/drivers/gpu/drm" ]; then
    find "$SLIM_MOD/kernel/drivers/gpu/drm" -name "*.ko" \
      | grep -vE "rockchip|panel|bridge|drm\.ko|drm_kms" \
      | xargs rm -f 2>/dev/null || true
  fi
  if [ -d "$SLIM_MOD/kernel/drivers/media" ]; then
    find "$SLIM_MOD/kernel/drivers/media" -name "*.ko" \
      | grep -vE "rockchip|v4l2|videobuf|v4l" \
      | xargs rm -f 2>/dev/null || true
  fi
  if [ -d "$SLIM_MOD/kernel/sound/soc" ]; then
    find "$SLIM_MOD/kernel/sound/soc" -name "*.ko" \
      | grep -vE "rockchip|simple|soc-core|soc-utils" \
      | xargs rm -f 2>/dev/null || true
  fi
  # 删除其他 SoC 驱动
  for soc in sunxi amlogic mediatek qcom imx exynos bcm samsung; do
    find "$SLIM_MOD/kernel" -path "*/$soc*" -name "*.ko" -delete 2>/dev/null || true
  done
  # 删除 wifi 里非 rtl88/rtw88 的
  if [ -d "$SLIM_MOD/kernel/drivers/net/wireless" ]; then
    find "$SLIM_MOD/kernel/drivers/net/wireless" -name "*.ko" \
      | grep -vE "rtl88|rtw88|rtl8|cfg80211|mac80211|mt76" \
      | xargs rm -f 2>/dev/null || true
  fi

  MODULES_SLIM_MB=$(du -sm "$SLIM_MOD" | awk '{print $1}')
  log "  精简后 modules: ${MODULES_SLIM_MB} MiB"
  MODULES_SRC_TO_USE="$SLIM_MOD"
else
  log "  完整模式：使用原始 modules"
  MODULES_SRC_TO_USE="$MODULES_SRC"
fi

# 挂载 rootfs 替换 modules
mkdir -p "$WORK_DIR/rootfs_mnt"
sudo mount -o loop "$ROOTFS_RAW" "$WORK_DIR/rootfs_mnt"

AVAIL_MB=$(df -m "$WORK_DIR/rootfs_mnt" | tail -1 | awk '{print $4}')
MODULES_NEED_MB=$(du -sm "$MODULES_SRC_TO_USE" | awk '{print $1}')
log "  rootfs 可用空间: ${AVAIL_MB} MiB"
log "  需要空间: ${MODULES_NEED_MB} MiB"

if [ "$AVAIL_MB" -lt "$((MODULES_NEED_MB + 20))" ]; then
  log "  空间不足，需要扩容..."
  sudo umount "$WORK_DIR/rootfs_mnt"
  # 扩到原大小 + modules 大小 + 512 MiB 余量
  target_mb=$((ORIG_MB + MODULES_NEED_MB + 512))
  [ "$target_mb" -lt 1536 ] && target_mb=1536
  log "  扩容 raw: ${ORIG_MB} MiB -> ${target_mb} MiB"
  truncate -s "$((target_mb * 1024 * 1024))" "$ROOTFS_RAW"
  e2fsck -f -y "$ROOTFS_RAW" >/dev/null 2>&1 || true
  resize2fs "$ROOTFS_RAW" >/dev/null 2>&1
  sudo mount -o loop "$ROOTFS_RAW" "$WORK_DIR/rootfs_mnt"
fi

# 删除旧 modules
if [ -d "$WORK_DIR/rootfs_mnt/lib/modules" ]; then
  sudo rm -rf "$WORK_DIR/rootfs_mnt/lib/modules"
fi

# 复制新 modules
sudo mkdir -p "$WORK_DIR/rootfs_mnt/lib/modules/$MODULES_NAME"
sudo cp -a "$MODULES_SRC_TO_USE"/. "$WORK_DIR/rootfs_mnt/lib/modules/$MODULES_NAME/"

# 校验
NEW_MOD_MB=$(sudo du -sm "$WORK_DIR/rootfs_mnt/lib/modules/$MODULES_NAME" | awk '{print $1}')
USED_MB=$(df -m "$WORK_DIR/rootfs_mnt" | tail -1 | awk '{print $3}')
AVAIL_MB=$(df -m "$WORK_DIR/rootfs_mnt" | tail -1 | awk '{print $4}')
log "  新 modules: ${NEW_MOD_MB} MiB"
log "  rootfs 使用: ${USED_MB} MiB (剩余 ${AVAIL_MB} MiB)"

sudo umount "$WORK_DIR/rootfs_mnt"

# 转回 sparse
img2simg "$ROOTFS_RAW" "$ROOTFS_IMG"
log "  rootfs.img sparse: $(stat -c%s "$ROOTFS_IMG") bytes"

# ============================================================
# 7. 替换 uInitrd
# ============================================================
log "========== [7/9] 替换 uInitrd =========="
UINITRD=$(find "$FLIPPY_CACHE/boot" -name "uInitrd-*" | head -1)
if [ -n "$UINITRD" ]; then
  cp "$UINITRD" "$TARGET_DIR/uInitrd"
  log "  uInitrd 已替换: $(stat -c%s "$TARGET_DIR/uInitrd") bytes"
else
  log "  WARNING: 找不到 uInitrd"
fi

# ============================================================
# 8. 修改 parameter.txt（kernel 40 MiB -> 48 MiB）
# ============================================================
log "========== [8/9] 修改 parameter.txt =========="
PARAM="$TARGET_DIR/parameter.txt"
log "  原始:"
grep CMDLINE "$PARAM" | head -1

ORIG_PAT='0x00014000@0x00012000(kernel),0x00010000@0x00026000(boot),0x00010000@0x00036000(recovery),0x00200000@0x00046000(rootfs),0x00200000@0x00246000(userdata:grow),-@0x00446000(opt:grow)'
NEW_PAT='0x00018000@0x00012000(kernel),0x00010000@0x0002a000(boot),0x00010000@0x0003a000(recovery),0x00200000@0x0004a000(rootfs),0x00200000@0x0024a000(userdata:grow),-@0x0044a000(opt:grow)'

if grep -q "0x00018000@0x00012000(kernel)" "$PARAM"; then
  log "  已扩展，跳过"
else
  sed -i "s|$ORIG_PAT|$NEW_PAT|" "$PARAM"
  grep -q "0x00018000@0x00012000(kernel)" "$PARAM" || { err "parameter.txt 修改失败"; grep CMDLINE "$PARAM"; exit 1; }
  log "  已扩展 kernel 40 MiB -> 48 MiB"
fi

# ============================================================
# 9. 生成最终镜像 + 验证
# ============================================================
log "========== [9/9] 生成最终镜像 =========="
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
assert data[0:4] == b'KRNL', 'KRNL missing'
code0 = int.from_bytes(data[8:12], 'little')
assert code0 == 0xd503201f, f'code0 not NOP: 0x{code0:08x}'
idx = data.find(b'ARM\x64')
assert idx == 0x40, f'magic at 0x{idx:x}'
print('  ✓ kernel 分区: KRNL + NOP + ARM64 magic@0x40')
print('  ✓ 固件含 flippy 内核')
PYEOF

log "=========================================="
log "✓ 完成 (version $VERSION)"
log "  输出: $OUTPUT_IMG"
log "  大小: $(stat -c%s "$OUTPUT_IMG") bytes"
log "=========================================="