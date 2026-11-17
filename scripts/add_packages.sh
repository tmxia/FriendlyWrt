#!/bin/bash
set -e

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

# Disable OpenWrt SDK/IB/MakeToolchain (speed up friendlywrt build)
sed -i -e '/CONFIG_MAKE_TOOLCHAIN=y/d' "$CONFIG_FILE"
sed -i -e 's/CONFIG_IB=y/# CONFIG_IB is not set/g' "$CONFIG_FILE"
sed -i -e 's/CONFIG_SDK=y/# CONFIG_SDK is not set/g' "$CONFIG_FILE"

# Update and install Clashoo feed
(cd friendlywrt && ./scripts/feeds update clashoo && ./scripts/feeds install -a -p clashoo)

# Enable kernel INET_DIAG dependencies for Clashoo
cd friendlywrt
KERNEL_VERSION=$(grep '^KERNEL_PATCHVER' target/linux/rockchip/Makefile | awk '{print $3}')
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

# Patch build-kernel.sh to fix rtw88 FIELD_PREP_CONST for kernel 6.1
echo ""
echo "=== Patching build-kernel.sh for rtw88 compatibility ==="
python3 << 'PYEOF'
import re, pathlib

PATCH = r'''
        # FIX_RTW88_BEGIN
        if [ -d rtw88 ]; then
            # Only rewrite *usages* of FIELD_PREP_CONST. Preprocessor lines are
            # skipped on purpose: the driver already ships a version-guarded
            # compat shim ("#define FIELD_PREP_CONST FIELD_PREP"). Rewriting
            # that line turned it into "#define FIELD_PREP FIELD_PREP", which
            # collides with include/linux/bitfield.h:112 and aborts the build
            # with: error: "FIELD_PREP" redefined.
            find rtw88 -type f \( -name '*.c' -o -name '*.h' \) -print0 |
                xargs -0 -r sed -i '/^[[:space:]]*#/!s/FIELD_PREP_CONST/FIELD_PREP/g' || true
            if grep -rq '^[[:space:]]*#[[:space:]]*define[[:space:]]*FIELD_PREP[[:space:]]*FIELD_PREP' rtw88; then
                echo "ERROR: rtw88 FIELD_PREP compat shim corrupted by patch"
                exit 1
            fi
            if [ -f rtw88/rtw8723bs.c ] && ! grep -q SDIO_VENDOR_ID_REALTEK rtw88/rtw8723bs.c; then
                {
                    printf '#ifndef SDIO_VENDOR_ID_REALTEK\n#define SDIO_VENDOR_ID_REALTEK 0x024c\n#endif\n'
                    printf '#ifndef SDIO_DEVICE_ID_REALTEK_RTW8723BS\n#define SDIO_DEVICE_ID_REALTEK_RTW8723BS 0xb723\n#endif\n'
                    cat rtw88/rtw8723bs.c
                } > rtw88/rtw8723bs.c.tmp && mv rtw88/rtw8723bs.c.tmp rtw88/rtw8723bs.c
            fi
        fi
        # FIX_RTW88_END
'''

ok = False
for f in pathlib.Path("scripts/sd-fuse").glob("build-kernel*.sh"):
    s = f.read_text()
    if "FIX_RTW88_END" in s:
        print("  already patched: %s" % f)
        ok = True
        continue
    m = re.search(r'^[ \t]*git clone [^\n]*rtw88[^\n]*$', s, re.MULTILINE)
    if not m:
        print("  no clone line in: %s" % f)
        continue
    end = s.find("\n", m.end()) + 1
    f.write_text(s[:end] + PATCH + s[end:])
    print("  patched: %s" % f)
    ok = True

if not ok:
    raise SystemExit("ERROR: no build-kernel.sh patched")
PYEOF

if ! grep -l "FIX_RTW88_END" scripts/sd-fuse/build-kernel*.sh > /dev/null 2>&1; then
    echo "ERROR: rtw88 patch not applied"
    exit 1
fi
echo "=== rtw88 patch OK ==="

echo "All configurations applied and verified."
