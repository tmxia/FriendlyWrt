#!/bin/bash
# replace-kernel.sh - 支持6.18/6.12/6.6/6.1，PE→KRNL转换 + kernel分区自动扩容
set -euo pipefail

VERSION="2026-09-11-v17-pe-convert-resize"
log()  { echo -e "\033[0;32m[replace]\033[0m $*"; }
warn() { echo -e "\033[0;33m[replace]\033[0m $*"; }
err()  { echo -e "\033[0;31m[replace]\033[0m $*" >&2; }
log "replace-kernel.sh version: $VERSION"

IMAGES_TGZ="$1"; SDFUSE_DIR="$2"; DIST_NAME="$3"; OUTPUT_IMG="$4"
TARGET_MODEL="${TARGET_MODEL:-r5s}"
KERNEL_VERSION="${KERNEL_VERSION:-6.18.y}"

log "参数: images=$(basename "$IMAGES_TGZ"), model=$TARGET_MODEL, version=$KERNEL_VERSION"

WORK_DIR=$(mktemp -d /tmp/replace-kernel.XXXXXX)
trap "rm -rf $WORK_DIR" EXIT
log "工作目录: $WORK_DIR"

# ============================================================
# 1. 解压 images.tgz
# ============================================================
log "========== [1/8] 解压 images.tgz =========="
mkdir -p "$WORK_DIR/base"
tar xzf "$IMAGES_TGZ" -C "$WORK_DIR/base"
BASE_DIR=$(find "$WORK_DIR/base" -maxdepth 2 -type d -name "friendlywrt*" | head -1)
[ -z "$BASE_DIR" ] && { err "找不到顶层目录"; exit 1; }
log "  顶层: $BASE_DIR"

# ============================================================
# 2. 扫描内核版本 (6.18/6.12/6.6/6.1)
# ============================================================
log "========== [2/8] 扫描 $KERNEL_VERSION 内核 =========="

declare -A VER_TO_SOURCE
SCAN_LIST=(
  "ophub/kernel:kernel_rk35xx"
  "ophub/kernel:kernel_flippy"
  "breakingbadboy/OpenWrt:kernel_rk35xx"
  "breakingbadboy/OpenWrt:kernel_stable"
)

case "$KERNEL_VERSION" in
  6.18*|6.18.y) PREFIX="6.18" ;;
  6.12*|6.12.y) PREFIX="6.12" ;;
  6.6*|6.6.y)   PREFIX="6.6" ;;
  6.1*|6.1.y)   PREFIX="6.1" ;;
  auto|"")      PREFIX="" ;;
  *)            PREFIX="$KERNEL_VERSION" ;;
esac
log "  版本前缀: ${PREFIX:-auto}"

for target in "${SCAN_LIST[@]}"; do
  REPO="${target%%:*}"; RELEASE="${target##*:}"
  log "  扫描 $REPO / $RELEASE ..."

  ASSETS=$(gh release view "$RELEASE" --repo "$REPO" --json assets --jq '.assets[].name' 2>/dev/null || echo "")
  [ -z "$ASSETS" ] && { log "    (无资产)"; continue; }

  if [ -n "$PREFIX" ]; then
    VERS=$(echo "$ASSETS" | grep -E "^${PREFIX}\.[0-9]+\.tar\.gz$" | sed 's/\.tar\.gz//' | sort -V || echo "")
  else
    VERS=$(echo "$ASSETS" | grep -E '^6\.[0-9]+\.[0-9]+\.tar\.gz$' | sed 's/\.tar\.gz//' | sort -V || echo "")
  fi

  if [ -z "$VERS" ]; then
    log "    (无匹配)"
    continue
  fi

  log "    匹配版本:"
  echo "$VERS" | sed 's/^/      /'

  for v in $VERS; do
    [ -z "${VER_TO_SOURCE[$v]:-}" ] && VER_TO_SOURCE["$v"]="$REPO:$RELEASE"
  done
done

if [ ${#VER_TO_SOURCE[@]} -eq 0 ]; then
  err "  无匹配 $KERNEL_VERSION 的内核"
  exit 1
fi

SELECTED_VER=$(printf '%s\n' "${!VER_TO_SOURCE[@]}" | sort -V | tail -1)
SELECTED_SOURCE="${VER_TO_SOURCE[$SELECTED_VER]}"
SELECTED_REPO="${SELECTED_SOURCE%%:*}"
SELECTED_RELEASE="${SELECTED_SOURCE##*:}"

log ""
log "  ============ 决策 ============"
log "  选中版本: $SELECTED_VER"
log "  来源: $SELECTED_REPO / $SELECTED_RELEASE"

# ============================================================
# 3. 下载并解压
# ============================================================
log "========== [3/8] 下载 $SELECTED_VER =========="

KERNEL_CACHE="/tmp/kernel-cache-${SELECTED_RELEASE}/${SELECTED_VER}"
if [ ! -f "$KERNEL_CACHE/.ready" ]; then
  rm -rf "$KERNEL_CACHE"; mkdir -p "$KERNEL_CACHE"; cd "$KERNEL_CACHE"
  URL="https://github.com/${SELECTED_REPO}/releases/download/${SELECTED_RELEASE}/${SELECTED_VER}.tar.gz"
  log "  URL: $URL"

  DOWNLOAD_OK=false
  wget -q --timeout=120 --tries=2 "$URL" -O kernel.tar.gz 2>/dev/null && DOWNLOAD_OK=true
  [ "$DOWNLOAD_OK" != "true" ] && curl -L -f --connect-timeout 60 --max-time 300 "$URL" -o kernel.tar.gz 2>/dev/null && DOWNLOAD_OK=true
  [ "$DOWNLOAD_OK" != "true" ] && { err "下载失败"; exit 1; }

  tar xzf kernel.tar.gz

  LOCAL_KDIR="$SELECTED_VER"
  [ ! -d "$LOCAL_KDIR" ] && LOCAL_KDIR=$(find . -maxdepth 2 -type d -name "*${SELECTED_VER}*" ! -path "./boot*" ! -path "./dtb*" ! -path "./modules*" | head -1)
  [ -z "$LOCAL_KDIR" ] && { err "找不到内核目录"; exit 1; }

  echo "$KERNEL_CACHE/$LOCAL_KDIR" > "$KERNEL_CACHE/.topdir"

  for type in boot dtb modules; do
    TAR=$(find "$LOCAL_KDIR" -maxdepth 1 -name "${type}-*.tar.gz" | head -1)
    [ -z "$TAR" ] && [ "$type" = "dtb" ] && TAR=$(find "$LOCAL_KDIR" -maxdepth 1 -name "dtb-rockchip-*.tar.gz" | head -1)
    [ -n "$TAR" ] && tar xzf "$TAR" -C "$KERNEL_CACHE" && log "  ✓ 解压 $type"
  done

  touch .ready
fi
KERNEL_TOPDIR=$(cat "$KERNEL_CACHE/.topdir" 2>/dev/null || echo "$KERNEL_CACHE/$SELECTED_VER")
log "  缓存: $KERNEL_CACHE"

# ============================================================
# 4. 复制骨架
# ============================================================
log "========== [4/8] 复制骨架 =========="
TARGET_DIR="$SDFUSE_DIR/$DIST_NAME"
rm -rf "$TARGET_DIR"
cp -a "$BASE_DIR" "$TARGET_DIR"

# ============================================================
# 5. 构造 kernel.img —— PE→KRNL 转换
# ============================================================
log "========== [5/8] 构造 kernel.img =========="

IMAGE_FILE=""
for pattern in "vmlinuz-*" "Image" "Image-*" "kernel*.img" "*.bin"; do
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
  log "  >>> KRNL 格式，直接使用"
  cp "$IMAGE_FILE" "$TARGET_DIR/kernel.img"
elif [ "$MAGIC" = "d00dfeed" ]; then
  log "  >>> FIT 格式，直接使用"
  cp "$IMAGE_FILE" "$TARGET_DIR/kernel.img"
else
  log "  >>> 调用 PE 解析器..."
  python3 - "$IMAGE_FILE" "$TARGET_DIR/kernel.img" <<'PYEOF'
import sys, struct, os

src, dst = sys.argv[1], sys.argv[2]
data = open(src, 'rb').read()

is_pe = data[0:2] == b'MZ'
if is_pe:
    print(f"    检测到 PE 格式 (MZ signature)")
    pe_off = struct.unpack_from('<I', data, 0x3C)[0]
    print(f"    PE header offset: 0x{pe_off:x}")

    if data[pe_off:pe_off+4] != b'PE\x00\x00':
        print(f"    ✗ PE 签名不匹配，回退为裸机处理")
        is_pe = False
    else:
        coff = pe_off + 4
        machine = struct.unpack_from('<H', data, coff)[0]
        num_sections = struct.unpack_from('<H', data, coff + 2)[0]
        opt_size = struct.unpack_from('<H', data, coff + 16)[0]
        print(f"    Machine: 0x{machine:04x} (0xaa64 = ARM64)")
        print(f"    Sections: {num_sections}")
        print(f"    Optional header size: {opt_size}")

        sec_start = coff + 20 + opt_size
        sections = []
        for i in range(num_sections):
            sec_off = sec_start + i * 40
            name = data[sec_off:sec_off+8].rstrip(b'\x00').decode('ascii', 'ignore')
            raw_size = struct.unpack_from('<I', data, sec_off + 16)[0]
            raw_off = struct.unpack_from('<I', data, sec_off + 20)[0]
            sections.append((name, raw_off, raw_size))
            print(f"      Section {i}: {name:<8} RawOff=0x{raw_off:08x} RawSize=0x{raw_size:08x}")

        linux_sec = next((s for s in sections if s[0] == '.linux'), None)
        text_sec = next((s for s in sections if s[0] == '.text'), None)
        target = linux_sec or text_sec

        if target:
            name, raw_off, raw_size = target
            print(f"    >>> 提取节 '{name}': offset=0x{raw_off:x}, size={raw_size}")
            kernel_data = data[raw_off:raw_off + raw_size]
            print(f"    提取大小: {len(kernel_data)} bytes")
            magic_pos = kernel_data.find(b'ARM\x64')
            print(f"    ARM64 magic 位置: 0x{magic_pos:x}")
            data = kernel_data
        else:
            print(f"    ✗ 找不到 .linux 或 .text 节，回退为裸机处理")
            is_pe = False

if not is_pe:
    print(f"    作为裸机 ARM64 Image 处理")
    magic_pos = data.find(b'ARM\x64')
    print(f"    ARM64 magic 位置: 0x{magic_pos:x}")

    if magic_pos == 0x38:
        print(f"    ✓ 标准 ARM64 Image 头")
        code0 = struct.unpack_from('<I', data, 0x00)[0]
        if code0 != 0xd503201f:
            print(f"    修复 code0: 0x{code0:08x} -> NOP")
            data = bytearray(data)
            data[0x00:0x04] = b'\x1f\x20\x03\xd5'
            data = bytes(data)
    else:
        print(f"    ⚠ magic 位置异常 (0x{magic_pos:x})，不做修改")

knl_size = len(data)
size_hex = struct.pack('<I', knl_size)
with open(dst, 'wb') as f:
    f.write(b'KRNL')
    f.write(size_hex)
    f.write(data)

out = open(dst, 'rb').read(128)
assert out[0:4] == b'KRNL', 'KRNL missing'
out_size = struct.unpack_from('<I', out, 4)[0]
magic_pos2 = out.find(b'ARM\x64')
print(f"    KRNL size: {out_size}")
print(f"    magic@:    0x{magic_pos2:x}")
if magic_pos2 == 0x40:
    print(f"    ✓✓✓ KRNL 转换成功")
elif magic_pos2 > 0:
    print(f"    ✓ KRNL 转换完成 (magic@0x{magic_pos2:x})")
else:
    print(f"    ⚠ KRNL 转换完成但未找到 ARM64 magic")
PYEOF
fi

log "  新 kernel.img: $(stat -c%s "$TARGET_DIR/kernel.img") bytes"

# ============================================================
# 5.5 动态扩容 kernel 分区（新增关键修复）
# ============================================================
log "========== [5.5/8] 扩容 kernel 分区 =========="

PARAM_FILE="$TARGET_DIR/parameter.txt"
[ -f "$PARAM_FILE" ] || { err "缺少 parameter.txt"; exit 1; }
log "  修改前:"
sed 's/^/    /' "$PARAM_FILE"

python3 - "$PARAM_FILE" "$(stat -c%s "$TARGET_DIR/kernel.img")" <<'PARAM_PYEOF'
import re, sys
param_file, kernel_size = sys.argv[1], int(sys.argv[2])

with open(param_file) as f:
    content = f.read()

# 匹配 0xSIZE@0xOFFSET(kernel)
kernel_re = re.compile(r'0x([0-9a-fA-F]+)@(0x[0-9a-fA-F]+)\(kernel\)',
                       re.IGNORECASE)
m = kernel_re.search(content)
if not m:
    print("[param] 未找到 kernel 分区，跳过"); sys.exit(0)

old_size   = int(m.group(1), 16)
kernel_off = int(m.group(2), 16)
kernel_end = kernel_off + old_size

need_sectors = (kernel_size + 511) // 512
rounded  = ((need_sectors + 0xFFF) // 0x1000) * 0x1000  # 2MiB 对齐
new_size = max(rounded, old_size)

print(f"[param] old  = 0x{old_size:x} ({old_size*512/1024/1024:.1f} MiB)")
print(f"[param] need = 0x{need_sectors:x} sectors ({need_sectors*512/1024/1024:.1f} MiB)")
print(f"[param] new  = 0x{new_size:x} ({new_size*512/1024/1024:.1f} MiB)")

if new_size == old_size:
    print("[param] 容量足够，无需扩容"); sys.exit(0)

delta = new_size - old_size

# 替换 kernel 分区大小（保留原 offset）
new_kernel = f'0x{new_size:08x}@{m.group(2)}(kernel)'
content = content[:m.start()] + new_kernel + content[m.end():]

# kernel 之后的所有 @offset 整体平移
def shift(match):
    off = int(match.group(1), 16)
    if off >= kernel_end:
        return f'@0x{off + delta:08x}'
    return match.group(0)

content = re.sub(r'@0x([0-9a-fA-F]+)', shift, content)

with open(param_file, 'w') as f:
    f.write(content)
print(f"[param] parameter.txt 已更新 (delta = {delta} sectors = {delta*512/1024/1024:.1f} MiB)")
PARAM_PYEOF

log "  修改后:"
sed 's/^/    /' "$PARAM_FILE"

# ============================================================
# 6. dtb + uInitrd
# ============================================================
log "========== [6/8] dtb + uInitrd =========="

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

# ============================================================
# 7. 生成镜像
# ============================================================
log "========== [7/8] 生成镜像 =========="
cd "$SDFUSE_DIR"
chmod +x mk-sd-image.sh
rm -f out/*.img
set +e
yes | ./mk-sd-image.sh "$DIST_NAME" > /tmp/mk-sd.log 2>&1
MK_EXIT=$?
set -e
echo "  mk-sd-image.sh exit=$MK_EXIT"
tail -40 /tmp/mk-sd.log | sed 's/^/    /'

FOUND_IMG=$(find out -maxdepth 1 -name "*.img" -print -quit)
[ -z "$FOUND_IMG" ] && { err "未生成镜像"; exit 1; }
mv "$FOUND_IMG" "$OUTPUT_IMG"

# ============================================================
# 8. 最终验证
# ============================================================
log "========== [8/8] 验证 =========="
KERNEL_OFFSET=$((0x12000 * 512))
python3 - "$OUTPUT_IMG" "$KERNEL_OFFSET" <<'PYEOF'
import sys
img, off = sys.argv[1], int(sys.argv[2])
with open(img, 'rb') as f:
    f.seek(off); data = f.read(128)
assert data[0:4] == b'KRNL', 'KRNL missing'
knl_size = int.from_bytes(data[4:8], 'little')
code0    = int.from_bytes(data[8:12], 'little')
idx = data.find(b'ARM\x64')
print(f"    KRNL size: {knl_size}")
print(f"    code0:     0x{code0:08x} ({'NOP' if code0 == 0xd503201f else '??'})")
print(f"    magic@:    0x{idx:x}")
assert idx == 0x40, f'ARM64 magic 位置错误: 0x{idx:x}'
print("    ✓✓✓ 最终镜像含有效内核")
PYEOF

log "=========================================="
log "✓ 完成 (version $VERSION)"
log "  内核: $SELECTED_VER"
log "  来源: $SELECTED_REPO / $SELECTED_RELEASE"
log "  输出: $OUTPUT_IMG ($(($(stat -c%s "$OUTPUT_IMG")/1024/1024)) MiB)"
log "=========================================="