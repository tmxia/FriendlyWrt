#!/bin/bash
# ---------------------------------------------------------------------------
# Backport the rtw88 SDIO identifiers into kernel headers.
#
# The out-of-tree rtw88 driver built by ./build.sh kernel (sources generated
# under scripts/sd-fuse/out/rtw88) carries its own SDIO match table:
#
#   { SDIO_DEVICE(SDIO_VENDOR_ID_REALTEK, SDIO_DEVICE_ID_REALTEK_RTW8723BS) },
#
# Both identifiers only entered include/linux/mmc/sdio_ids.h together with the
# upstream rtw88 SDIO support (Linux v6.13), so against the 6.1 Rockchip kernel
# the build stops with:
#
#   rtw8723bs.c:16:29: error: 'SDIO_VENDOR_ID_REALTEK' undeclared here
#   ./include/linux/mmc/sdio_func.h:95:20: note: in definition of macro 'SDIO_DEVICE'
#
# That diagnostic is what tells us WHERE to patch.  The note points at
# sdio_func.h, which is the header rtw8723bs.c actually reaches through its own
# "sdio.h", while the constants live in sdio_ids.h -- a header this driver never
# includes.  Injecting into sdio_ids.h alone therefore changes nothing at all;
# the failing translation unit still sees the identifiers as undeclared.
#
# So sdio_func.h is the primary target: it is provably part of the include chain
# of every file that failed.  sdio_ids.h is patched as well because that is the
# natural home for the identifiers, and it is free of charge -- the replacement
# lists are token-for-token identical, so a file that happens to include both
# headers still compiles without a "macro redefined" warning (-Werror).
#
# They are plain compile-time constants, so making them visible to every module
# built against kernel/ is enough, and unlike patching the driver sources it
# does not depend on when those sources are generated.
#
# Usage: kernel_rtw88_sdio_ids.sh [<kernel include dir>]
# ---------------------------------------------------------------------------
set -e

INC_DIR="${1:-kernel/include/linux}"

BEGIN_MARK='FriendlyWrt: rtw88 SDIO ids backport -- begin'
END_MARK='FriendlyWrt: rtw88 SDIO ids backport -- end'

# values taken from upstream include/linux/mmc/sdio_ids.h (0x024c is the Realtek
# SDIO vendor id, 0xb723 the RTL8723BS SDIO device id)
IDS="SDIO_VENDOR_ID_REALTEK:0x024c SDIO_DEVICE_ID_REALTEK_RTW8723BS:0xb723"

# primary target first: <linux/mmc/sdio_func.h> is provably in the include chain
PRIMARY="$INC_DIR/mmc/sdio_func.h"
HEADERS="$PRIMARY $INC_DIR/mmc/sdio_ids.h"

if [ ! -f "$PRIMARY" ]; then
    echo "ERROR: $PRIMARY not found, cannot backport rtw88 SDIO ids" >&2
    exit 1
fi

for HDR in $HEADERS; do
    [ -f "$HDR" ] || continue

    # our defines are #ifndef guarded, so the only thing to undo from an earlier
    # run is our own marked block
    sed -i "/$BEGIN_MARK/,/$END_MARK/d" "$HDR"

    block=""
    for pair in $IDS; do
        id="${pair%%:*}"
        value="${pair#*:}"

        if grep -qE "^#[[:space:]]*define[[:space:]]+${id}([[:space:]]|$)" "$HDR"; then
            echo "$HDR already defines $id, left untouched"
            continue
        fi

        block="${block}#ifndef ${id}
#define ${id} ${value}
#endif
"
    done

    if [ -n "$block" ]; then
        printf '/* %s */\n%s/* %s */\n' "$BEGIN_MARK" "$block" "$END_MARK" >> "$HDR"
        echo "Backported rtw88 SDIO ids into $HDR"
    fi
done

# the backport is only useful if the identifiers are visible through the header
# the failing driver really includes, so that one is verified strictly
missing=0
for pair in $IDS; do
    id="${pair%%:*}"
    if ! grep -qE "^#[[:space:]]*define[[:space:]]+${id}([[:space:]]|$)" "$PRIMARY"; then
        echo "ERROR: failed to backport $id into $PRIMARY" >&2
        missing=1
    fi
done
[ "$missing" -eq 0 ] || exit 1

echo "=== rtw88 SDIO ids backport verified ($PRIMARY) ==="
