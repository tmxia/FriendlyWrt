#!/bin/bash
# ---------------------------------------------------------------------------
# Backport the rtw88 SDIO identifiers into the kernel's sdio_ids.h.
#
# The out-of-tree rtw88 driver built by ./build.sh kernel registers rtw8723bs
# with its own SDIO match table:
#
#   { SDIO_DEVICE(SDIO_VENDOR_ID_REALTEK, SDIO_DEVICE_ID_REALTEK_RTW8723BS) },
#
# Both identifiers only entered include/linux/mmc/sdio_ids.h together with the
# upstream rtw88 SDIO support (Linux v6.13).  Against an older kernel the build
# stops with:
#
#   rtw8723bs.c: error: 'SDIO_VENDOR_ID_REALTEK' undeclared here
#
# They are plain compile-time constants, so giving them to every module built
# against kernel/ is enough - and, unlike patching the driver sources, it does
# not depend on when those sources are unpacked.
#
# Usage: kernel_rtw88_sdio_ids.sh [<kernel include dir>]
# ---------------------------------------------------------------------------
set -e

HDR_DIR="${1:-kernel/include/linux}"
HDR="$HDR_DIR/mmc/sdio_ids.h"

BEGIN_MARK='FriendlyWrt: rtw88 SDIO ids backport -- begin'
END_MARK='FriendlyWrt: rtw88 SDIO ids backport -- end'

if [ ! -f "$HDR" ]; then
    echo "WARNING: $HDR not found, rtw88 SDIO id backport skipped" >&2
    exit 1
fi

# values taken from upstream include/linux/mmc/sdio_ids.h
IDS="SDIO_VENDOR_ID_REALTEK:0x024c SDIO_DEVICE_ID_REALTEK_RTW8723BS:0xb723"

# our defines are #ifndef guarded, so the only thing to undo from an earlier
# run is our own block
sed -i "/$BEGIN_MARK/,/$END_MARK/d" "$HDR"

for pair in $IDS; do
    id="${pair%%:*}"
    value="${pair#*:}"

    if grep -qE "^#[[:space:]]*define[[:space:]]+${id}([[:space:]]|$)" "$HDR"; then
        echo "$HDR already defines $id, left untouched"
        continue
    fi

    {
        echo "/* $BEGIN_MARK */"
        echo "#ifndef $id"
        echo "#define $id $value"
        echo "#endif"
        echo "/* $END_MARK */"
    } >> "$HDR"
    echo "Backported $id = $value into $HDR"
done

for pair in $IDS; do
    id="${pair%%:*}"
    if ! grep -qE "^#[[:space:]]*define[[:space:]]+${id}([[:space:]]|$)" "$HDR"; then
        echo "ERROR: failed to backport $id into $HDR" >&2
        exit 1
    fi
done

echo "=== rtw88 SDIO ids backport verified ($HDR) ==="
