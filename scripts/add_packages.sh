#!/bin/bash
set -e

# Ensure feeds.conf exists
(cd friendlywrt && { [ ! -f feeds.conf ] && cp feeds.conf.default feeds.conf; })

# Add Clashoo feed
FEED_CONF="friendlywrt/feeds.conf"
grep -q "src-git clashoo" "$FEED_CONF" || echo "src-git clashoo https://github.com/kenzok8/openwrt-clashoo.git;main" >> "$FEED_CONF"

# Add Clashoo config
CONFIG_FILE="configs/rockchip/01-nanopi"
grep -q "CONFIG_PACKAGE_luci-app-clashoo" "$CONFIG_FILE" || cat >> "$CONFIG_FILE" << EOF

# Clashoo packages
CONFIG_PACKAGE_clashoo=y
CONFIG_PACKAGE_luci-app-clashoo=y
CONFIG_PACKAGE_luci-i18n-clashoo-zh-cn=y
CONFIG_PACKAGE_kmod-inet-diag=y
EOF

# Packages to ensure
ENSURE_PKGS="
bc vsftpd sudo unzip file logrotate coreutils-stat lsof jq wireguard-tools python3-light
# netdata luci-app-cpufreq luci-app-netdata
"

# Write ensure packages to config
for pkg in $ENSURE_PKGS; do
    grep -q "CONFIG_PACKAGE_${pkg}=y" "$CONFIG_FILE" || echo "CONFIG_PACKAGE_${pkg}=y" >> "$CONFIG_FILE"
done

# Update Clashoo feed
(cd friendlywrt && ./scripts/feeds update clashoo && ./scripts/feeds install -a -p clashoo)

# Remove kmod-inet-diag dependency from Clashoo
if [ -d friendlywrt/feeds/clashoo ]; then
    find friendlywrt/feeds/clashoo -name "Makefile" -exec sed -i 's/+kmod-inet-diag//g' {} \;
fi

# UCI defaults for side-router (CIDR format for 24.10+ compatibility)
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
/etc/init.d/network restart
/etc/init.d/firewall restart
exit 0
EOF
chmod +x friendlywrt/files/etc/uci-defaults/99-custom

# Enter build dir
cd friendlywrt

# Disable global options
for opt in CONFIG_ALL_KMODS CONFIG_ALL_NONSHARED CONFIG_DEVEL CONFIG_BUILDBOT; do
    sed -i "s/^${opt}=.*/# ${opt} is not set/" .config || echo "# ${opt} is not set" >> .config
done

make defconfig

# Packages to disable
DISABLE_PKGS="
adblock luci-app-adblock
aria2 luci-app-aria2
sqm-scripts nft-qos luci-app-nft-qos luci-app-sqm
ddns-scripts luci-app-ddns
miniupnpd-nftables luci-app-upnp
samba4-libs samba4-server luci-app-samba4
minidlna luci-app-minidlna
luci-proto-3g luci-proto-qmi qmi-utils uqmi umbim usb-modeswitch-official iwlwifi-firmware-ax200 iwlwifi-firmware-ax210  mt76x2-firmware mt792x-firmware
luci-app-diskman collectd luci-app-statistics
ppp luci-proto-ppp
luci-app-watchcat
"

# Disable all unwanted packages
for pkg in $DISABLE_PKGS; do
    sed -i "s/^CONFIG_PACKAGE_${pkg}=.*/# CONFIG_PACKAGE_${pkg} is not set/" .config
    grep -q "^# CONFIG_PACKAGE_${pkg} is not set" .config || echo "# CONFIG_PACKAGE_${pkg} is not set" >> .config
done

# Force-enable required packages
for pkg in $ENSURE_PKGS; do
    sed -i "/^# CONFIG_PACKAGE_${pkg} is not set/d" .config
    sed -i "s/^CONFIG_PACKAGE_${pkg}=.*/CONFIG_PACKAGE_${pkg}=y/" .config
    grep -q "^CONFIG_PACKAGE_${pkg}=y" .config || echo "CONFIG_PACKAGE_${pkg}=y" >> .config
done

make oldconfig

# Print final status (auto-generated)
echo "=== Final package status ==="
check_pkg() {
    grep -q "^CONFIG_PACKAGE_$1=y" .config && echo "  [ENABLED]  $1" && return
    grep -q "^# CONFIG_PACKAGE_$1 is not set" .config && echo "  [DISABLED] $1" && return
    echo "  [UNKNOWN]  $1"
}
echo "--- ENABLED ---"
for pkg in $ENSURE_PKGS; do check_pkg "$pkg"; done
echo "--- DISABLED ---"
for pkg in $DISABLE_PKGS; do check_pkg "$pkg"; done

cd ..
echo "All configurations applied."