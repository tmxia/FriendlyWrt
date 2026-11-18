#!/bin/bash
set -e

# This workflow checks out FriendlyWrt and then runs this script from project/,
# i.e. "cd project && bash ../scripts/add_packages.sh".  A bare "scripts/..."
# path therefore does NOT point at this repository: project/scripts is a
# separate manifest project, so helpers kept next to this file must be resolved
# relative to this file itself.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Ensure feeds.conf exists
(cd friendlywrt && { [ ! -f feeds.conf ] && cp feeds.conf.default feeds.conf; })

# Add Clashoo feed if missing
FEED_CONF="friendlywrt/feeds.conf"
grep -q "src-git clashoo" "$FEED_CONF" || echo "src-git clashoo https://github.com/kenzok8/openwrt-clashoo.git;main" >> "$FEED_CONF"

# Add Clashoo packages to target config
CONFIG_FILE="configs/rockchip/01-nanopi"
grep -q "CONFIG_PACKAGE_luci-app-clashoo" "$CONFIG_FILE" || cat >> "$CONFIG_FILE" << EOF

# Clashoo packages
CONFIG_PACKAGE_clashoo=y
CONFIG_PACKAGE_luci-app-clashoo=y
CONFIG_PACKAGE_luci-i18n-clashoo-zh-cn=y
CONFIG_PACKAGE_kmod-inet-diag=y
EOF

# Required system packages
ENSURE_PKGS="
bc vsftpd sudo unzip file procd logrotate coreutils-stat lsof jq wireguard-tools python3-light
"

for pkg in $ENSURE_PKGS; do
    grep -q "CONFIG_PACKAGE_${pkg}=y" "$CONFIG_FILE" || echo "CONFIG_PACKAGE_${pkg}=y" >> "$CONFIG_FILE"
done

# Update and install Clashoo feed
(cd friendlywrt && ./scripts/feeds update clashoo && ./scripts/feeds install -a -p clashoo)

# Enable kernel INET_DIAG dependencies for Clashoo
cd friendlywrt
KERNEL_VERSION=$(grep '^KERNEL_PATCHVER' target/linux/rockchip/Makefile | 
awk '{print $3}')
[ -z "$KERNEL_VERSION" ] && KERNEL_VERSION="6.1"
KERNEL_CONFIG_FILE="target/linux/rockchip/config-${KERNEL_VERSION}"
touch "$KERNEL_CONFIG_FILE"

sed -i '/^# CONFIG_INET_DIAG is not set/d' "$KERNEL_CONFIG_FILE"
sed -i '/^# CONFIG_INET_TCP_DIAG is not set/d' "$KERNEL_CONFIG_FILE"
sed -i '/^# CONFIG_INET_UDP_DIAG is not set/d' "$KERNEL_CONFIG_FILE"
sed -i '/^# CONFIG_INET_RAW_DIAG is not set/d' "$KERNEL_CONFIG_FILE"
echo "CONFIG_INET_DIAG=y" >> "$KERNEL_CONFIG_FILE"
echo "CONFIG_INET_TCP_DIAG=y" >> "$KERNEL_CONFIG_FILE"
echo "CONFIG_INET_UDP_DIAG=y" >> "$KERNEL_CONFIG_FILE"
echo "CONFIG_INET_RAW_DIAG=y" >> "$KERNEL_CONFIG_FILE"
echo "Kernel config updated: $KERNEL_CONFIG_FILE"
cd ..

# UCI default settings for side-router
mkdir -p friendlywrt/files/etc/uci-defaults
cat > friendlywrt/files/etc/uci-defaults/99-custom << 'EOF'
#!/bin/sh
uci set network.lan.ipaddr='192.168.3.3/24'
uci set network.lan.gateway='192.168.3.1'
uci set network.lan.dns='192.168.3.1'
uci delete network.lan.netmask 2>/dev/null
uci commit network
uci set dhcp.lan.ignore='1'
uci commit dhcp
uci set firewall.@zone[0].network='lan'
uci commit firewall
uci set network.wan.clientid=''
uci commit network

printf "tony\ntony\n" | passwd root

uci set luci.main.mediaurlbase='/luci-static/bootstrap'
uci delete luci.themes.Argon 2>/dev/null || true
uci commit luci
rm -rf /tmp/luci-* /tmp/luci-modulecache/* 2>/dev/null
/etc/init.d/uhttpd restart

/etc/init.d/network restart
/etc/init.d/firewall restart
exit 0
EOF
chmod +x friendlywrt/files/etc/uci-defaults/99-custom

cd friendlywrt

# Disable global build options that may cause conflicts
for opt in CONFIG_ALL_KMODS CONFIG_ALL_NONSHARED CONFIG_DEVEL CONFIG_BUILDBOT; do
    sed -i "s/^${opt}=.*/# ${opt} is not set/" .config || echo "# ${opt} is not set" >> .config
done

make defconfig

# Packages to explicitly remove
DISABLE_PKGS="
adblock luci-app-adblock
aria2 luci-app-aria2
sqm-scripts nft-qos luci-app-nft-qos luci-app-sqm
ddns-scripts luci-app-ddns
miniupnpd-nftables luci-app-upnp
samba4-libs samba4-server luci-app-samba4
minidlna luci-app-minidlna
luci-proto-3g luci-proto-qmi qmi-utils uqmi umbim usb-modeswitch-official iwlwifi-firmware-ax200 iwlwifi-firmware-ax210 mt76x2-firmware mt792x-firmware
luci-app-diskman collectd luci-app-statistics
luci-app-watchcat luci-theme-openwrt-2020
luci-app-cpufreq luci-i18n-cpufreq-zh-cn
luci-app-hd-idle hd-idle luci-i18n-hd-idle-zh-cn
luci-app-nlbwmon nlbwmon luci-i18n-nlbwmon-zh-cn
luci-app-smartdns smartdns luci-i18n-smartdns-zh-cn
"

for pkg in $DISABLE_PKGS; do
    sed -i "s/^CONFIG_PACKAGE_${pkg}=.*/# CONFIG_PACKAGE_${pkg} is not set/" .config
    grep -q "^# CONFIG_PACKAGE_${pkg} is not set" .config || echo "# CONFIG_PACKAGE_${pkg} is not set" >> .config
done
echo "=== Disabled packages ==="
for pkg in $DISABLE_PKGS; do
    grep -q "^# CONFIG_PACKAGE_${pkg} is not set" .config && echo "  [DISABLED] $pkg" || echo "  [MISS]     $pkg"
done

# Force-enable required packages
for pkg in $ENSURE_PKGS; do
    sed -i "/^# CONFIG_PACKAGE_${pkg} is not set/d" .config
    sed -i "s/^CONFIG_PACKAGE_${pkg}=.*/CONFIG_PACKAGE_${pkg}=y/" .config
    grep -q "^CONFIG_PACKAGE_${pkg}=y" .config || echo "CONFIG_PACKAGE_${pkg}=y" >> .config
done
echo "=== Enabled system packages ==="
for pkg in $ENSURE_PKGS; do
    grep -q "^CONFIG_PACKAGE_${pkg}=y" .config && echo "  [ENABLED]  $pkg" || echo "  [MISS]     $pkg"
done

# Force-enable Clashoo packages in .config
for pkg in clashoo luci-app-clashoo luci-i18n-clashoo-zh-cn kmod-inet-diag; do
    sed -i "/^# CONFIG_PACKAGE_${pkg} is not set/d" .config
    sed -i "/^CONFIG_PACKAGE_${pkg}=/d" .config
    echo "CONFIG_PACKAGE_${pkg}=y" >> .config
done
echo "=== Enabled Clashoo packages ==="
for pkg in clashoo luci-app-clashoo luci-i18n-clashoo-zh-cn kmod-inet-diag; do
    grep -q "^CONFIG_PACKAGE_${pkg}=y" .config && echo "  [ENABLED]  $pkg" || echo "  [MISS]     $pkg"
done

cd ..

# Adjust userdata partition size by version
BASE_MK="device/friendlyelec/rk3568/base.mk"
CUR_UD=$(grep '^TARGET_USERDATA_PARTSIZE=' "$BASE_MK" | cut -d= -f2)
if [ "$CUR_UD" = "1024" ]; then
    sed -i 's|^TARGET_USERDATA_PARTSIZE=.*|TARGET_USERDATA_PARTSIZE=2048|' "$BASE_MK"
    sed -i 's|^[[:space:]]*TARGET_SD_IMAGESIZE=3000|    TARGET_SD_IMAGESIZE=4096|' "$BASE_MK"
    echo "userdata partition set to 2G (24.10)"
elif [ "$CUR_UD" = "1536" ]; then
    sed -i 's|^TARGET_USERDATA_PARTSIZE=.*|TARGET_USERDATA_PARTSIZE=2560|' "$BASE_MK"
    sed -i 's|^[[:space:]]*TARGET_SD_IMAGESIZE=3584|    TARGET_SD_IMAGESIZE=4864|' "$BASE_MK"
    echo "userdata partition set to 2.5G (25.12)"
else
    echo "Unknown TARGET_USERDATA_PARTSIZE=$CUR_UD, skipping"
fi
echo "=== Partition config after patch ==="
grep -E "TARGET_(ROOTFS_PARTSIZE|USERDATA_PARTSIZE|SD_IMAGESIZE)=" "$BASE_MK"

# ============================================
# Kernel header backport: FIELD_PREP_CONST()
# ============================================
# ./build.sh kernel builds the out-of-tree rtw88 driver (sources under
# scripts/sd-fuse/out/rtw88) against kernel/.  Those sources are written for
# Linux >= 6.11 and use FIELD_PREP_CONST(), which is missing from the 6.1
# Rockchip kernel, so the build stops at the first user with:
#   rtw8723b.c: error: implicit declaration of function 'FIELD_PREP_CONST'
#
# The driver is inconsistent about it: some files call the macro expecting the
# kernel to provide it (rtw8723b.c), others bring their own fallback
#   #define FIELD_PREP_CONST FIELD_PREP            (rtw8703b.c:618)
#
# Because of that fallback the backport must be that very same token sequence:
# C allows a macro to be redefined when the replacement list is identical
# (C11 6.10.3p2), which keeps both kinds of files warning-free under -Werror.
# A functional definition (re-implementing FIELD_PREP_CONST()) fixes
# rtw8723b.c but breaks rtw8703b.c with '"FIELD_PREP_CONST" redefined'.
#
# Doing it in the kernel headers (instead of patching the driver sources)
# keeps it independent of where those sources come from and of when they are
# unpacked, since every module built against kernel/ inherits it.
KERNEL_DIR="kernel"
KERNEL_INCLUDE="$KERNEL_DIR/include/linux"

sync_kernel_source() {
    [ -d "$KERNEL_INCLUDE" ] && return 0
    [ -d .repo ] || return 1
    command -v repo >/dev/null 2>&1 || return 1

    # kernel is not part of the workflow's "Download source" step, resolve the
    # project name from the manifest (falls back to the path used by repo sync)
    local proj="kernel" name=""
    if [ -f .repo/manifests/rk3568.xml ]; then
        name=$(grep -E '<project[^>]*path="kernel"' .repo/manifests/rk3568.xml \
               | head -n 1 | sed -n 's/.*name="\([^"]*\)".*/\1/p')
        [ -n "$name" ] && proj="$name"
    fi

    echo "kernel/ missing, syncing repo project '$proj' ..."
    repo sync -c "$proj" --no-clone-bundle || true
    [ -d "$KERNEL_INCLUDE" ]
}

kernel_version() {
    local maj min
    maj=$(sed -n 's/^VERSION *= *//p' "$KERNEL_DIR/Makefile" 2>/dev/null | head -n 1)
    min=$(sed -n 's/^PATCHLEVEL *= *//p' "$KERNEL_DIR/Makefile" 2>/dev/null | head -n 1)
    case "$maj" in ''|*[!0-9]*) maj=6 ;; esac
    case "$min" in ''|*[!0-9]*) min=1 ;; esac
    KVER_MAJOR="$maj"
    KVER_MINOR="$min"
}

backport_field_prep_const() {
    local hdrs=() hdr ok=0
    for hdr in "$KERNEL_INCLUDE/bits.h" "$KERNEL_INCLUDE/bitfield.h"; do
        if [ -f "$hdr" ]; then
            hdrs+=("$hdr")
        fi
    done
    [ ${#hdrs[@]} -gt 0 ] || return 1

    kernel_version
    echo "Patching FIELD_PREP_CONST for kernel ${KVER_MAJOR}.${KVER_MINOR} ..."

    KVER_MAJOR="$KVER_MAJOR" KVER_MINOR="$KVER_MINOR" python3 - "${hdrs[@]}" << 'PYEOF'
import io
import os
import re
import sys

BEGIN = "/* FriendlyWrt: FIELD_PREP_CONST backport -- begin */"
END = "/* FriendlyWrt: FIELD_PREP_CONST backport -- end */"

BLOCK = "\n".join([
    BEGIN,
    "/*",
    " * This kernel predates Linux v6.11, which introduced FIELD_PREP_CONST().",
    " * Out-of-tree drivers written against newer kernels (the rtw88 sources",
    " * under scripts/sd-fuse/out/rtw88) call it, so without this they abort",
    " * with \"implicit declaration of function 'FIELD_PREP_CONST'\" under",
    " * -Werror.  Defining it here covers every module built against kernel/,",
    " * no matter where that module's sources come from or when they appear.",
    " *",
    " * Deliberately a plain alias of FIELD_PREP and nothing more: those very",
    " * drivers carry their own fallback in their sources",
    " *",
    " *     #define FIELD_PREP_CONST FIELD_PREP",
    " *",
    " * and C only allows a macro to be redefined when the replacement list is",
    " * token-for-token identical.  A functional definition here would instead",
    " * be rejected as \"macro redefined\" (-Werror), e.g. in rtw8703b.c.",
    " */",
    "#ifndef FIELD_PREP_CONST",
    "#define FIELD_PREP_CONST FIELD_PREP",
    "#endif",
    END,
    "",
])

MARKED_RE = re.compile(re.escape(BEGIN) + r".*?" + re.escape(END) + r"[ \t]*\n?", re.S)
DEFINE_START = re.compile(r"^[ \t]*#[ \t]*define[ \t]+FIELD_PREP_CONST\b")

major = int(os.environ.get("KVER_MAJOR") or 6)
minor = int(os.environ.get("KVER_MINOR") or 1)
native = (major, minor) >= (6, 11)


def remove_defines(text):
    """Drop every '#define FIELD_PREP_CONST ...' statement incl. continuations."""
    lines = text.split("\n")
    out = []
    i = 0
    while i < len(lines):
        if DEFINE_START.match(lines[i]):
            while i < len(lines):
                continuation = lines[i].rstrip().endswith("\\")
                i += 1
                if not continuation:
                    break
            continue
        out.append(lines[i])
        i += 1
    return "\n".join(out)


def write(path, text):
    if not text.endswith("\n"):
        text += "\n"
    with io.open(path, "w", encoding="utf-8", errors="surrogateescape") as f:
        f.write(text)


for path in sys.argv[1:]:
    with io.open(path, "r", encoding="utf-8", errors="surrogateescape") as f:
        original = f.read()

    text = MARKED_RE.sub("", original)

    if native:
        # nothing to backport, only make sure no stale copy of our own block stays
        if text != original:
            write(path, text)
            print("Removed stale FIELD_PREP_CONST backport from %s" % path)
        else:
            print("%s already provides FIELD_PREP_CONST, left untouched" % path)
        continue

    # kernel < 6.11: whatever FIELD_PREP_CONST definition exists here was added
    # by an earlier run of this script (upstream had none), replace it
    text = remove_defines(text).rstrip("\n")
    write(path, text + "\n\n" + BLOCK)
    print("Backported FIELD_PREP_CONST (= FIELD_PREP) into %s" % path)
PYEOF

    for hdr in "${hdrs[@]}"; do
        if grep -q '^#define FIELD_PREP_CONST FIELD_PREP$' "$hdr"; then
            echo "=== FIELD_PREP_CONST backport verified ($hdr) ==="
            ok=1
        fi
    done
    [ "$ok" -eq 1 ]
}

if sync_kernel_source; then
    if backport_field_prep_const; then
        echo "rtw88 FIELD_PREP_CONST compatibility ensured."
    else
        echo "WARNING: could not backport FIELD_PREP_CONST into kernel headers" >&2
    fi
    # rtw88 SDIO ids (SDIO_VENDOR_ID_REALTEK / SDIO_DEVICE_ID_REALTEK_RTW8723BS)
    # live in scripts/kernel_rtw88_sdio_ids.sh of THIS repository, hence the
    # SCRIPT_DIR prefix; a bare "scripts/..." would hit project/scripts instead
    # and, because of the "||", be skipped without any trace.
    SDIO_HELPER="$SCRIPT_DIR/kernel_rtw88_sdio_ids.sh"
    if [ ! -f "$SDIO_HELPER" ]; then
        echo "WARNING: $SDIO_HELPER is missing, rtw88 SDIO ids not backported" >&2
    elif bash "$SDIO_HELPER" "$(pwd)/$KERNEL_INCLUDE"; then
        echo "rtw88 SDIO ids compatibility ensured."
    else
        echo "WARNING: rtw88 SDIO id backport failed, rtw8723bs.c will not build" >&2
    fi
else
    echo "WARNING: kernel/ sources unavailable, kernel header backports skipped" >&2
fi

echo "All configurations applied and verified."
