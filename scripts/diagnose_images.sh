#!/bin/bash
# 编译完成后，一次输出所有镜像格式信息
set +e

OUT="${1:-bin/targets/rockchip/armv8}"

sep() { printf '%.0s%s\n' {1..70} | tr ' ' '='; }

analyze_raw() {
    local F="$1"
    local SIZE
    SIZE=$(stat -c%s "$F" 2>/dev/null)
    echo "  size: $SIZE bytes ($((SIZE/1024/1024)) MB)"

    local M4
    M4=$(head -c 4 "$F" 2>/dev/null | od -An -tx1 | tr -d ' \n')
    echo "  magic[0:4] (hex): $M4"

    local H16
    H16=$(head -c 16 "$F" 2>/dev/null | od -An -tx1 | tr -d ' \n')
    echo "  head[0:16] (hex): $H16"

    for off in 0 512 1024 8192 16384 32768 65536 262144; do
        local SIG
        SIG=$(dd if="$F" bs=1 skip=$off count=8 2>/dev/null | tr -d '\0' | tr -cd '[:print:]')
        [ -n "$SIG" ] && echo "  str[$off]: '$SIG'"
    done

    # Android Sparse
    if [ "$M4" = "3aff26ed" ]; then
        echo "  >>> Android Sparse Image"
        python3 - "$F" <<'PY'
import struct, sys
with open(sys.argv[1],'rb') as fp:
    d = fp.read(28)
    (magic, major, minor, fhs, chs, blk, tblks, tchunks, crc) = struct.unpack('<IHHHHIIII', d)
    print(f"      v{major}.{minor} blk_sz={blk} total_blks={tblks} chunks={tchunks}")
    print(f"      展开后: {tblks*blk} bytes ({tblks*blk//1024//1024} MB)")
PY
    fi

    # FIT (U-Boot)
    if [ "$M4" = "d00dfeed" ]; then
        echo "  >>> FIT Image (U-Boot)"
    fi

    # GPT at 512
    local SIG512
    SIG512=$(dd if="$F" bs=1 skip=512 count=8 2>/dev/null | tr -d '\0')
    if [ "$SIG512" = "EFI PART" ]; then
        echo "  >>> raw GPT (at offset 512)"
        python3 - "$F" <<'PY'
import struct, sys
try:
    f = open(sys.argv[1], 'rb')
    f.seek(512)
    hdr = f.read(92)
    if hdr[:8] != b'EFI PART':
        sys.exit(0)
    fields = struct.unpack('<8sIIIIQQQQI4xIII', hdr)
    (_, _, _, _, _, mylba, altlba, first_usable, last_usable,
     gpt_lba, num_entries, entsz, entcrc) = fields
    print(f"      my_lba={mylba} alt_lba={altlba} gpt_lba={gpt_lba}")
    print(f"      first_usable={first_usable} last_usable={last_usable}")
    print(f"      n_entries={num_entries} ent_sz={entsz}")
    f.seek(gpt_lba * 512)
    ents = f.read(num_entries * entsz)
    types = {
        bytes.fromhex('af3dc60f838472478e793d69d8477de4'): 'Linux fs',
        bytes.fromhex('ebd0a0a2b9e5443387c068b6b72699c7'): 'EFI System',
        bytes.fromhex('a2a0d0eb4ee5443387c068b6b72699c7'): 'Microsoft Basic',
    }
    for i in range(num_entries):
        e = ents[i*entsz:(i+1)*entsz]
        if e[:16] == b'\x00'*16:
            continue
        tguid = e[:16]
        first, last, attr = struct.unpack('<QQQ', e[16:40])
        name = e[56:128].decode('utf-16-le', 'ignore').rstrip('\x00')
        tname = types.get(tguid, tguid.hex())
        mb = (last - first + 1) * 512 // 1024 // 1024
        print(f"      p{i+1}: {tname} LBA {first}..{last} ({mb}MB) name='{name}'")
except Exception as e:
    print(f"      parse error: {e}")
PY
    fi

    local MBR
    MBR=$(dd if="$F" bs=1 skip=510 count=2 2>/dev/null | od -An -tx1 | tr -d ' \n')
    if [ "$MBR" = "55aa" ]; then
        echo "  >>> MBR boot signature at offset 510"
    fi
}

sep
echo "== 目录内容: $OUT =="
sep
if [ ! -d "$OUT" ]; then
    echo "目录不存在: $OUT"
    exit 0
fi
ls -la "$OUT"/ 2>/dev/null

sep
echo "== nanopi-r5s 相关全部文件 =="
sep
ls -lh "$OUT"/*nanopi-r5s* 2>/dev/null

sep
echo "== 逐文件详细分析 =="
sep

for f in "$OUT"/*nanopi-r5s*; do
    [ -f "$f" ] || continue
    echo ""
    echo "================================================================"
    echo "FILE: $(basename "$f")"
    echo "================================================================"
    echo "file(1): $(file -b "$f")"

    if [[ "$f" == *.gz ]]; then
        TMP=$(mktemp)
        if gunzip -c "$f" 2>/dev/null > "$TMP"; then
            analyze_raw "$TMP"
        else
            echo "  gunzip 失败"
        fi
        rm -f "$TMP"
    else
        analyze_raw "$f"
    fi
done

sep
echo "== 目录中所有文件的 file(1) 概览 =="
sep
for f in "$OUT"/*; do
    [ -f "$f" ] || continue
    printf '%-70s %s\n' "$(basename "$f")" "$(file -b "$f")"
done

sep
echo "== 诊断完成 =="
sep