#!/bin/bash
set -e

# Init feeds.conf
(cd friendlywrt && {
    [ ! -f feeds.conf ] && cp feeds.conf.default feeds.conf
})

# Add Clashoo feed
FEED_CONF="friendlywrt/feeds.conf"
if ! grep -q "src-git clashoo" "$FEED_CONF"; then
    echo "src-git clashoo https://github.com/kenzok8/openwrt-clashoo.git;main" >> "$FEED_CONF"
fi

# Add Clashoo config
CONFIG_FILE="configs/rockchip/01-nanopi"
if ! grep -q "CONFIG_PACKAGE_luci-app-clashoo" "$CONFIG_FILE"; then
    cat >> "$CONFIG_FILE" << EOF

# Clashoo packages
CONFIG_PACKAGE_clashoo=y
CONFIG_PACKAGE_luci-app-clashoo=y
CONFIG_PACKAGE_luci-i18n-clashoo-zh-cn=y
CONFIG_PACKAGE_kmod-inet-diag=y
EOF
fi

# Packages to enable
ENSURE_PKGS="
    bc
    vsftpd
    sudo
    unzip
    file
    logrotate
    coreutils-stat
    lsof
    jq
    wireguard-tools
    python3-light
    netdata
    luci-app-cpufreq
    luci-app-netdata
"

for pkg in $ENSURE_PKGS; do
    if ! grep -q "CONFIG_PACKAGE_${pkg}=y" "$CONFIG_FILE"; then
        echo "CONFIG_PACKAGE_${pkg}=y" >> "$CONFIG_FILE"
    fi
done

# Update feeds
(cd friendlywrt && ./scripts/feeds update clashoo)
(cd friendlywrt && ./scripts/feeds install -a -p clashoo)

# Remove kmod-inet-diag dependency
if [ -d friendlywrt/feeds/clashoo ]; then
    find friendlywrt/feeds/clashoo -name "Makefile" -exec sed -i 's/+kmod-inet-diag//g' {} \;
fi

# uci-defaults for side-router setup
mkdir -p friendlywrt/files/etc/uci-defaults
cat > friendlywrt/files/etc/uci-defaults/99-custom << 'EOF'
#!/bin/sh
uci set network.lan.ipaddr='192.168.3.3/24'
uci set network.lan.gateway='192.168.3.1'
uci set network.lan.dns='192.168.3.1'
uci commit network

uci set dhcp.lan.ignore='1'
uci commit dhcp

printf "tony\ntony\n" | passwd root > /dev/null 2>&1

uci set luci.main.mediaurlbase='/luci-static/bootstrap'
uci delete luci.themes.Argon 2>/dev/null || true
uci commit luci

sed -i '/net.ipv4.conf.*rp_filter/d' /etc/sysctl.conf
cat >> /etc/sysctl.conf <<EOF
net.ipv4.conf.all.rp_filter=0
net.ipv4.conf.default.rp_filter=0
net.ipv4.conf.lan.rp_filter=0
EOF
sysctl -p >/dev/null 2>&1

rm -rf /tmp/luci-* /tmp/luci-modulecache/* 2>/dev/null || true

exit 0
EOF
chmod +x friendlywrt/files/etc/uci-defaults/99-custom

cd friendlywrt

# Verify uci-defaults
if [ ! -f files/etc/uci-defaults/99-custom ]; then
    echo "[ERROR] uci-defaults file not found!" >&2
    exit 1
fi

# Packages to disable
DISABLE_PKGS="
    adblock luci-app-adblock
    aria2 luci-app-aria2
    sqm-scripts nft-qos luci-app-nft-qos luci-app-sqm
    ddns-scripts luci-app-ddns
    miniupnpd-nftables luci-app-upnp
    samba4-libs samba4-server luci-app-samba4
    minidlna luci-app-minidlna
    luci-proto-3g luci-proto-qmi qmi-utils uqmi umbim usb-modeswitch-official
    iwlwifi-firmware-ax200 iwlwifi-firmware-ax210 rtl8822be-firmware rtl8822ce-firmware mt76x2-firmware mt792x-firmware
    luci-app-diskman
    collectd luci-app-statistics
    ppp luci-proto-ppp
    luci-app-watchcat
"

# configuration loop

# Base config
make defconfig

# Disable global knobs
for opt in ALL_KMODS ALL_NONSHARED DEVEL BUILDBOT; do
    sed -i "s/^CONFIG_${opt}=.*/# CONFIG_${opt} is not set/" .config
    grep -q "^# CONFIG_${opt} is not set" .config || echo "# CONFIG_${opt} is not set" >> .config
done
make oldconfig

# Disable unwanted packages
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

# Loop to fix packages re-enabled by dependencies
max_retries=5
for ((i=1; i<=max_retries; i++)); do
    changed=0
    for pkg in $DISABLE_PKGS; do
        if grep -q "^CONFIG_PACKAGE_${pkg}=y" .config; then
            sed -i "s/^CONFIG_PACKAGE_${pkg}=.*/# CONFIG_PACKAGE_${pkg} is not set/" .config
            changed=1
        fi
    done
    [ $changed -eq 0 ] && break
    make oldconfig
done

# Final status report
echo "=== Final package status ==="
check_pkg() {
    local pkg="$1"
    if grep -q "^CONFIG_PACKAGE_${pkg}=y" .config; then
        echo "  [ENABLED]  $pkg"
    elif grep -q "^# CONFIG_PACKAGE_${pkg} is not set" .config; then
        echo "  [DISABLED] $pkg"
    else
        echo "  [UNKNOWN]  $pkg"
    fi
}
echo "--- ENABLED ---"
for pkg in $ENSURE_PKGS; do check_pkg "$pkg"; done
echo "--- DISABLED ---"
for pkg in $DISABLE_PKGS; do check_pkg "$pkg"; done

cd ..
echo "All done."