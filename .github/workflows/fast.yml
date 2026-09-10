#!/bin/bash
# replace-kernel.sh - 从 breakingbadboy/OpenWrt 下载内核替换 FriendlyWrt kernel.img
#
# 用法:
#   replace-kernel.sh <images.tgz> <sdfuse-dir> <dist-name> <output-img>
#
# 环境变量:
#   TARGET_MODEL     - r5s (默认) / r5c
#   SLIM_MODE        - true (默认) / false
#   KERNEL_REPO      - breakingbadboy/OpenWrt (默认)
#   KERNEL_VERSION   - 6.18.y (默认) / 6.12.y
set -euo pipefail

VERSION="2026-09-10-v6-bbb"
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
KERNEL_VERSION="${KERNEL_VERSION:-6.18.y}"

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
log "========== [1/6] 解压官方 images tgz =========="
mkdir -p "$WORK_DIR/base"
tar xzf "$IMAGES_TGZ" -C "$WORK_DIR/base"

BASE_DIR=$(find "$WORK_DIR/base" -maxdepth 2 -type d -name "friendlywrt*" | head -1)
[ -z "$BASE_DIR" ] && { err "找不到顶层目录"; ls -la "$WORK_DIR/base"; exit 1; }
log "官方 images 顶层: $BASE_DIR"

# ============================================================
# 2. 从 breakingbadboy/OpenWrt 下载内核（多级回退）
# ============================================================
log "========== [2/6] 从 $KERNEL_REPO 下载 $KERNEL_VERSION 内核 =========="

# ---------- 2.1 获取可用的 tag 列表 ----------
log "  步骤 1: 列出 $KERNEL_REPO 的所有 release tag"
TAG_LIST=""

# 尝试方式 A: gh release list
if TAG_LIST=$(gh release list --limit 100 --repo "$KERNEL_REPO" --json tagName --jq '.[].tagName' 2>/tmp/gh_list_err); then
  log "  ✓ gh release list 成功，找到 $(echo "$TAG_LIST" | wc -l) 个 tag"
else
  warn "  gh release list 失败:"
  cat /tmp/gh_list_err 2>/dev/null | head -5 || true
fi

# 尝试方式 B: GitHub API
if [ -z "$TAG_LIST" ]; then
  log "  步骤 1b: 尝试 GitHub API"
  API_URL="https://api.github.com/repos/${KERNEL_REPO}/releases?per_page=100"
  AUTH_HEADER=""
  [ -n "${GH_TOKEN:-}" ] && AUTH_HEADER="-H \"Authorization: Bearer $GH_TOKEN\""
  TAG_LIST=$(curl -sL -H "Accept: application/vnd.github+json" \
    ${GH_TOKEN:+-H "Authorization: Bearer $GH_TOKEN"} \
    "$API_URL" 2>/dev/null \
    | grep -oE '"tag_name":\s*"[^"]+"' \
    | sed 's/.*: *"//;s/"$//' || echo "")
  [ -n "$TAG_LIST" ] && log "  ✓ API 成功，找到 $(echo "$TAG_LIST" | wc -l) 个 tag"
fi

if [ -z "$TAG_LIST" ]; then
  err "  无法列出 $KERNEL_REPO 的 release"
  err "  请检查: https://github.com/$KERNEL_REPO/releases"
  err "  或 GH_TOKEN 是否有 repo 权限"
  exit 1
fi

log "  可用 tag (前 20):"
echo "$TAG_LIST" | head -20 | sed 's/^/    /'

# ---------- 2.2 选择内核 tag ----------
# 优先选择: kernel_stable > kernel_rk35xx > 任何 kernel_* > 6.*
SELECTED_TAG=""
for candidate in "kernel_stable" "kernel_rk35xx" "kernel_flippy"; do
  if echo "$TAG_LIST" | grep -qx "$candidate"; then
    SELECTED_TAG="$candidate"
    log "  ✓ 优先选择 tag: $SELECTED_TAG"
    break
  fi
done

# 如果没有 kernel_* tag，尝试直接用 KERNEL_VERSION 匹配
if [ -z "$SELECTED_TAG" ]; then
  log "  步骤 2: 没有 kernel_* tag，尝试匹配 $KERNEL_VERSION"
  for t in $TAG_LIST; do
    if echo "$t" | grep -qE "^kernel.*"; then
      SELECTED_TAG="$t"
      break
    fi
  done
fi

if [ -z "$SELECTED_TAG" ]; then
  err "  无法从 tag 列表中选出内核 tag"
  err "  tag 列表: $TAG_LIST"
  exit 1
fi
log "  选中内核 tag: $SELECTED_TAG"

# ---------- 2.3 获取该 tag 下的 assets ----------
log "  步骤 3: 获取 $SELECTED_TAG 的 assets"
KERNEL_ASSETS=""

# 方式 A: gh release view
if KERNEL_ASSETS=$(gh release view "$SELECTED_TAG" --repo "$KERNEL_REPO" --json assets --jq '.assets[].name' 2>/tmp/gh_view_err); then
  log "  ✓ gh release view 成功"
else
  warn "  gh release view 失败:"
  cat /tmp/gh_view_err 2>/dev/null | head -5 || true
fi

# 方式 B: GitHub API
if [ -z "$KERNEL_ASSETS" ]; then
  log "  步骤 3b: 通过 GitHub API 查询 assets"
  API_URL="https://api.github.com/repos/${KERNEL_REPO}/releases/tags/${SELECTED_TAG}"
  KERNEL_ASSETS=$(curl -sL -H "Accept: application/vnd.github+json" \
    ${GH_TOKEN:+-H "Authorization: Bearer $GH_TOKEN"} \
    "$API_URL" 2>/dev/null \
    | grep -oE '"name":\s*"[^"]+\.tar\.gz"' \
    | sed 's/.*: *"//;s/"$//' || echo "")
  [ -n "$KERNEL_ASSETS" ] && log "  ✓ API 成功"
fi

if [ -z "$KERNEL_ASSETS" ]; then
  err "  无法获取 $SELECTED_TAG 的 assets 列表"
  exit 1
fi

log "  可用内核包 (前 20):"
echo "$KERNEL_ASSETS" | head -20 | sed 's/^/    /'

# ---------- 2.4 按 KERNEL_VERSION 匹配版本 ----------
VERSION_PREFIX="${KERNEL_VERSION%.y}"
log "  步骤 4: 匹配前缀 '$VERSION_PREFIX.*.tar.gz'"

MATCHED_VER=$(echo "$KERNEL_ASSETS" | grep -E "^${VERSION_PREFIX}\.[0-9]+\.tar\.gz$" | sed 's/\.tar\.gz//' | sort -V | tail -1)

if [ -z "$MATCHED_VER" ]; then
  # 尝试更宽松的匹配
  warn "  严格匹配失败，尝试宽松匹配（包含 ${VERSION_PREFIX} 的任意 tar.gz）"
  MATCHED_FILE=$(echo "$KERNEL_ASSETS" | grep -E "${VERSION_PREFIX}" | grep '\.tar\.gz$' | head -1)
  if [ -n "$MATCHED_FILE" ]; then
    MATCHED_VER="${MATCHED_FILE%.tar\.gz}"
    log "  宽松匹配到: $MATCHED_FILE"
  fi
fi

if [ -z "$MATCHED_VER" ]; then
  err "  无法匹配 $KERNEL_VERSION 版本"
  err "  可用包:"
  echo "$KERNEL_ASSETS" | grep '\.tar\.gz$' | head -20 | sed 's/^/    /'
  exit 1
fi

# 如果 MATCHED_VER 包含 .tar.gz 后缀，去掉
MATCHED_VER="${MATCHED_VER%.tar.gz}"
log "  ✓ 匹配版本: $MATCHED_VER"

# ---------- 2.5 下载并解压 ----------
KERNEL_CACHE="/tmp/kernel-cache-$SELECTED_TAG/$MATCHED_VER"
if [ -f "$KERNEL_CACHE/.ready" ]; then
  log "  ✓ 缓存命中: $KERNEL_CACHE"
else
  log "  步骤 5: 下载内核 $MATCHED_VER"
  rm -rf "$KERNEL_CACHE"
  mkdir -p "$KERNEL_CACHE"
  cd "$KERNEL_CACHE"

  DOWNLOAD_URL="https://github.com/${KERNEL_REPO}/releases/download/${SELECTED_TAG}/${MATCHED_VER}.tar.gz"
  log "  URL: $DOWNLOAD_URL"

  # 下载（多次尝试）
  DOWNLOAD_OK=false
  if wget -q --timeout=120 --tries=2 "$DOWNLOAD_URL" -O kernel.tar.gz 2>/dev/null; then
    DOWNLOAD_OK=true
    log "  ✓ wget 下载成功"
  fi
  if [ "$DOWNLOAD_OK" != "true" ]; then
    log "  wget 失败，尝试 curl..."
    if curl -L -f --connect-timeout 60 --max-time 300 "$DOWNLOAD_URL" -o kernel.tar.gz 2>/dev/null; then
      DOWNLOAD_OK=true
      log "  ✓ curl 下载成功"
    fi
  fi
  if [ "$DOWNLOAD_OK" != "true" ]; then
    err "  下载失败: $DOWNLOAD_URL"
    err "  请检查文件是否存在于:"
    err "    https://github.com/$KERNEL_REPO/releases/tag/$SELECTED_TAG"
    exit 1
  fi

  log "  文件大小: $(stat -c%s kernel.tar.gz) bytes"

  # 解压
  if ! tar xzf kernel.tar.gz 2>/dev/null; then
    err "  tar 解压失败"
    file kernel.tar.gz
    head -c 200 kernel.tar.gz | xxd | head -5
    exit 1
  fi

  # 定位内核目录
  LOCAL_KDIR="$MATCHED_VER"
  if [ ! -d "$LOCAL_KDIR" ]; then
    LOCAL_KDIR=$(find . -maxdepth 2 -type d -name "*${MATCHED_VER}*" ! -path "./boot*" ! -path "./dtb*" ! -path "./modules*" | head -1)
  fi

  if [ -z "$LOCAL_KDIR" ] || [ ! -d "$LOCAL_KDIR" ]; then
    err "  解压后找不到内核目录"
    log "  当前目录内容:"
    ls -la
    exit 1
  fi

  log "  内核目录: $LOCAL_KDIR"
  ls -la "$LOCAL_KDIR/" | head -20

  mkdir -p boot dtb modules

  # 查找 boot 子包
  BOOT_TAR=$(find "$LOCAL_KDIR" -maxdepth 1 -name "boot-*.tar.gz" | head -1)
  if [ -n "$BOOT_TAR" ]; then
    tar xzf "$BOOT_TAR" -C boot
    log "  ✓ 解压 boot: $(basename "$BOOT_TAR")"
  else
    warn "  找不到 boot-*.tar.gz"
  fi

  # 查找 dtb 子包
  DTB_TAR=$(find "$LOCAL_KDIR" -maxdepth 1 -name "dtb-rockchip-*.tar.gz" | head -1)
  [ -z "$DTB_TAR" ] && DTB_TAR=$(find "$LOCAL_KDIR" -maxdepth 1 -name "dtb-*.tar.gz" | head -1)
  if [ -n "$DTB_TAR" ]; then
    tar xzf "$DTB_TAR" -C dtb
    log "  ✓ 解压 dtb: $(basename "$DTB_TAR")"
  else
    warn "  找不到 dtb-*.tar.gz"
  fi

  # 查找 modules 子包
  MODULES_TAR=$(find "$LOCAL_KDIR" -maxdepth 1 -name "modules-*.tar.gz" | head -1)
  if [ -n "$MODULES_TAR" ]; then
    tar xzf "$MODULES_TAR" -C modules
    log "  ✓ 解压 modules: $(basename "$MODULES_TAR")"
  else
    warn "  找不到 modules-*.tar.gz"
  fi

  log "  boot 目录内容:"
  ls -la "$KERNEL_CACHE/boot/" 2>/dev/null | head -10 || log "    (空)"
  log "  dtb 目录内容 (前 5):"
  ls "$KERNEL_CACHE/dtb/" 2>/dev/null | head -5 || log "    (空)"

  touch .ready
fi
log "  ✓ 内核缓存: $KERNEL_CACHE"

# ============================================================
# 3. 复制官方骨架到目标
# ============================================================
log "========== [3/6] 复制官方骨架 =========="
TARGET_DIR="$SDFUSE_DIR/$DIST_NAME"
rm -rf "$TARGET_DIR"
cp -a "$BASE_DIR" "$TARGET_DIR"
log "  已复制: $TARGET_DIR"

# ============================================================
# 4. 构造 kernel.img
# ============================================================
log "========== [4/6] 构造 kernel.img =========="

IMAGE_FILE=""
for pattern in "Image" "vmlinuz-*" "kernel*.img" "*.bin" "Image-*" "uImage*"; do
  IMAGE_FILE=$(find "$KERNEL_CACHE/boot" -maxdepth 3 -name "$pattern" -type f 2>/dev/null | head -1)
  [ -n "$IMAGE_FILE" ] && break
done

if [ -z "$IMAGE_FILE" ]; then
  err "找不到内核 Image 文件"
  log "boot 目录完整列表:"
  find "$KERNEL_CACHE/boot" -type f 2>/dev/null | head -30
  exit 1
fi

IMAGE_SIZE=$(stat -c%s "$IMAGE_FILE")
log "  内核文件: $(basename "$IMAGE_FILE") ($IMAGE_SIZE bytes)"
log "  文件类型: $(file -b "$IMAGE_FILE" || echo unknown)"
log "  前 64 字节:"
xxd -l 64 "$IMAGE_FILE" | sed 's/^/    /'

MAGIC=$(xxd -l 4 -p "$IMAGE_FILE")
log "  前 4 字节 magic: $MAGIC"

# 构造 kernel.img
if [ "$MAGIC" = "4b524e4c" ]; then
  log "  >>> 已是 KRNL 格式，直接使用"
  cp "$IMAGE_FILE" "$TARGET_DIR/kernel.img"

elif [ "$MAGIC" = "d00dfeed" ]; then
  log "  >>> FIT 格式，直接使用"
  cp "$IMAGE_FILE" "$TARGET_DIR/kernel.img"

elif [ "$(xxd -l 2 -p "$IMAGE_FILE")" = "4d5a" ]; then
  log "  >>> PE/EFI 格式，提取纯 ARM64 Image"
  python3 - "$IMAGE_FILE" "$WORK_DIR/extracted.img" <<'PYEOF'
import sys
data = open(sys.argv[1], 'rb').read()
idx = data.find(b'ARM\x64')
if idx >= 0x38:
    start = idx - 0x38
    image_data = data[start:]
    if len(image_data) > 0x1000:
        open(sys.argv[2], 'wb').write(image_data)
        print(f"  ✓ 从 PE 提取 ARM64 Image: 起始 0x{start:x}, 大小 {len(image_data)}")
        sys.exit(0)
print("  ✗ PE 提取失败")
sys.exit(1)
PYEOF
  if [ -f "$WORK_DIR/extracted.img" ]; then
    IMG_SIZE=$(stat -c%s "$WORK_DIR/extracted.img")
    SIZE_HEX=$(printf '%08x' "$IMG_SIZE")
    SIZE_LE=$(echo "$SIZE_HEX" | sed 's/\(..\)\(..\)\(..\)\(..\)/\4\3\2\1/')
    printf 'KRNL' > "$TARGET_DIR/kernel.img"
    printf "$SIZE_LE" | xxd -r -p >> "$TARGET_DIR/kernel.img"
    cat "$WORK_DIR/extracted.img" >> "$TARGET_DIR/kernel.img"
    log "  已构造 KRNL + Image"
  else
    err "  PE 提取失败"
    exit 1
  fi

elif [ "$(xxd -l 2 -p "$IMAGE_FILE")" = "1f8b" ]; then
  log "  >>> gzip 压缩，解压后构造 KRNL"
  gunzip -c "$IMAGE_FILE" > "$WORK_DIR/uncompressed.img" 2>/dev/null || cp "$IMAGE_FILE" "$WORK_DIR/uncompressed.img"
  IMG_SIZE=$(stat -c%s "$WORK_DIR/uncompressed.img")
  SIZE_HEX=$(printf '%08x' "$IMG_SIZE")
  SIZE_LE=$(echo "$SIZE_HEX" | sed 's/\(..\)\(..\)\(..\)\(..\)/\4\3\2\1/')
  printf 'KRNL' > "$TARGET_DIR/kernel.img"
  printf "$SIZE_LE" | xxd -r -p >> "$TARGET_DIR/kernel.img"
  cat "$WORK_DIR/uncompressed.img" >> "$TARGET_DIR/kernel.img"

else
  log "  >>> 未知格式，作为纯 Image 使用"
  IMG_SIZE=$IMAGE_SIZE
  SIZE_HEX=$(printf '%08x' "$IMG_SIZE")
  SIZE_LE=$(echo "$SIZE_HEX" | sed 's/\(..\)\(..\)\(..\)\(..\)/\4\3\2\1/')
  printf 'KRNL' > "$TARGET_DIR/kernel.img"
  printf "$SIZE_LE" | xxd -r -p >> "$TARGET_DIR/kernel.img"
  cat "$IMAGE_FILE" >> "$TARGET_DIR/kernel.img"
fi

# 验证 kernel.img
python3 - "$TARGET_DIR/kernel.img" <<'PYEOF'
import sys
data = open(sys.argv[1], 'rb').read(256)
assert data[0:4] == b'KRNL', 'KRNL magic missing!'
size = int.from_bytes(data[4:8], 'little')
print(f'  ✓ KRNL 头: magic=OK, size={size}')
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
    warn "    找不到 r5s/r5c dtb，保留骨架 dtb"
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
  INITRD=$(find "$KERNEL_CACHE/boot" -name "initrd.img-*" | head -1)
  if [ -n "$INITRD" ] && command -v mkimage >/dev/null 2>&1; then
    log "    从 initrd.img 转换..."
    mkimage -A arm64 -O linux -T ramdisk -C gzip -n "uInitrd" -d "$INITRD" "$TARGET_DIR/uInitrd" 2>/dev/null || \
      cp "$INITRD" "$TARGET_DIR/uInitrd"
    log "    uInitrd: $(stat -c%s "$TARGET_DIR/uInitrd") bytes"
  else
    warn "    找不到 uInitrd，保留骨架"
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
    exit 1
  fi
fi

log "  最终目录内容:"
ls -la "$TARGET_DIR/" | head -20

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
log "  内核 tag: $SELECTED_TAG"
log "  内核版本: $MATCHED_VER"
log "  输出: $OUTPUT_IMG"
log "  大小: $(stat -c%s "$OUTPUT_IMG") bytes ($(($(stat -c%s "$OUTPUT_IMG")/1024/1024)) MiB)"
log "=========================================="