#!/bin/bash
# replace-kernel.sh - 最小化替换 flippy 内核
# 只替换: kernel.img / dtb(精简) / uInitrd / parameter.txt
# 不修改 rootfs.img（避免符号链接问题）
set -euo pipefail

VERSION="2026-09-10-v3-minimal"
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
log "  images.tgz:   $(basename "$IMAGES_TGZ")"
log "  sd-fuse dir:  $SDFUSE_DIR"
log "  dist name:    $DIST_NAME"
log "  output img:   $OUTPUT_IMG"
log "  target:       $TARGET_MODEL"
log "  slim mode:    $SLIM_MODE"

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
# 2. 下载并解压 flippy 内核
# ============================================================
log "========== [2/6] 获取 flippy 内核 =========="
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
  LOCAL_KDIR="$FLIPPY_VER"
  [ ! -d "$LOCAL_KDIR" ] && LOCAL_KDIR=$(find . -maxdepth 1 -type d -name "*$FLIPPY_VER*" | head -1)
  mkdir -p boot dtb modules
  tar xzf "$(find "$LOCAL_KDIR" -name 'boot-*.tar.gz' | head -1)" -C boot
  tar xzf "$(find "$LOCAL_KDIR" -name 'dtb-rockchip-*.tar.gz' | head -1)" -C dtb
  tar xzf "$(find "$LOCAL_KDIR" -name 'modules-*.tar.gz' | head -1)" -C modules
  touch .ready
fi
log "  flippy boot 目录:"
ls -la "$FLIPPY_CACHE/boot/"

# ============================================================
# 3. 复制官方骨架到目标
# ============================================================
log "========== [3/6] 复制官方骨架 =========="
TARGET_DIR="$SDFUSE_DIR/$DIST_NAME"
rm -rf "$TARGET_DIR"
cp -a "$BASE_DIR" "$TARGET_DIR"
log "  已复制: $TARGET_DIR -> $TARGET_DIR"

log "  骨架内容:"
ls -la "$TARGET_DIR/"

# ============================================================
# 4. 替换 kernel.img（含 NOP 修复）
# ============================================================
log "========== [4/6] 构造 flippy kernel.img =========="
VMLINUZ=$(find "$FLIPPY_CACHE/boot" -name "vmlinuz-*" | head -1)
[ -z "$VMLINUZ" ] && { err "找不到 vmlinuz"; exit 1; }
VMLINUZ_SIZE=$(stat -c%s "$VMLINUZ")
log "  flippy vmlinuz: $(basename "$VMLINUZ") ($VMLINUZ_SIZE bytes)"
log "  原 kernel.img: $(stat -c%s "$TARGET_DIR/kernel.img") bytes"

# 关键修复: code0 MZ 魔数 -> NOP (0xd503201f)
# U-Boot 跳转后执行 NOP 然后继续到 code1 分支
echo "1f2003d5" | xxd -r -p > "$WORK_DIR/vmlinuz_patched"
tail -c +5 "$VMLINUZ" >> "$WORK_DIR/vmlinuz_patched"

SIZE_HEX=$(printf '%08x' "$VMLINUZ_SIZE")
SIZE_LE=$(echo "$SIZE_HEX" | sed 's/\(..\)\(..\)\(..\)\(..\)/\4\3\2\1/')
printf 'KRNL' > "$TARGET_DIR/kernel.img"
printf "$SIZE_LE" | xxd -r -p >> "$TARGET_DIR/kernel.img"
cat "$WORK_DIR/vmlinuz_patched" >> "$TARGET_DIR/kernel.img"

python3 - "$TARGET_DIR/kernel.img" <<'PYEOF'
import sys
data = open(sys.argv[1], 'rb').read(256)
assert data[0:4] == b'KRNL', 'KRNL missing'
code0 = int.from_bytes(data[8:12], 'little')
assert code0 == 0xd503201f, f'code0 not NOP: 0x{code0:08x}'
idx = data.find(b'ARM\x64')
assert idx == 0x40, f'magic at 0x{idx:x}'
print('  ✓ kernel.img: KRNL + NOP + ARM64 magic@0x40')
PYEOF
log "  新 kernel.img: $(stat -c%s "$TARGET_DIR/kernel.img") bytes"

# ============================================================
# 5. 替换 dtb + uInitrd + parameter.txt
# ============================================================
log "========== [5/6] 替换 dtb + uInitrd + parameter.txt =========="

# 5.1 dtb 精简
log "  处理 dtb..."
if [ "$SLIM_MODE" = "true" ]; then
  FLIPPY_DTB_R5S=$(find "$FLIPPY_CACHE/dtb" -name "rk3568-nanopi-r5s.dtb" | head -1)
  FLIPPY_DTB_R5C=$(find "$FLIPPY_CACHE/dtb" -name "rk3568-nanopi-r5c.dtb" | head -1)
  log "    flippy r5s: ${FLIPPY_DTB_R5S:-无}"
  log "    flippy r5c: ${FLIPPY_DTB_R5C:-无}"

  if [ -d "$TARGET_DIR/dtb/rockchip" ]; then
    BEFORE=$(find "$TARGET_DIR/dtb" -name "*.dtb" | wc -l)
    rm -rf "$TARGET_DIR/dtb/rockchip"
    mkdir -p "$TARGET_DIR/dtb/rockchip"
    [ -n "$FLIPPY_DTB_R5S" ] && cp -f "$FLIPPY_DTB_R5S" "$TARGET_DIR/dtb/rockchip/"
    [ -n "$FLIPPY_DTB_R5C" ] && cp -f "$FLIPPY_DTB_R5C" "$TARGET_DIR/dtb/rockchip/"
    AFTER=$(find "$TARGET_DIR/dtb" -name "*.dtb" | wc -l)
    log "    dtb: $BEFORE -> $AFTER 个"
  fi
else
  log "    完整模式：使用骨架自带 dtb"
fi

# 5.2 uInitrd
log "  处理 uInitrd..."
UINITRD=$(find "$FLIPPY_CACHE/boot" -name "uInitrd-*" | head -1)
if [ -n "$UINITRD" ]; then
  cp "$UINITRD" "$TARGET_DIR/uInitrd"
  log "    uInitrd: $(stat -c%s "$TARGET_DIR/uInitrd") bytes"
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
# 6. 生成最终镜像 + 验证
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
assert data[0:4] == b'KRNL', 'KRNL missing'
code0 = int.from_bytes(data[8:12], 'little')
assert code0 == 0xd503201f, f'code0 not NOP: 0x{code0:08x}'
idx = data.find(b'ARM\x64')
assert idx == 0x40, f'magic at 0x{idx:x}'
print('  ✓ kernel 分区: KRNL + NOP + ARM64 magic@0x40')
PYEOF

log "=========================================="
log "✓ 完成 (version $VERSION)"
log "  输出: $OUTPUT_IMG"
log "  大小: $(stat -c%s "$OUTPUT_IMG") bytes ($(($(stat -c%s "$OUTPUT_IMG")/1024/1024)) MiB)"
log "=========================================="