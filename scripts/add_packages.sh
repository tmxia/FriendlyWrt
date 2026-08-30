#!/bin/bash
set -e

# ------------------------------------------------------------
# 1. Clean all non-kmod user-space packages from configs
#    (keep only kernel modules for board compatibility)
# ------------------------------------------------------------
for cf in configs/rockchip/*; do
    [ -f "$cf" ] || continue
    sed -i -e '/^CONFIG_PACKAGE_kmod-/! { /^CONFIG_PACKAGE_.*=[ym]$/d; }' "$cf"
done

# ------------------------------------------------------------
# 2. Remove build tools from 01-nanopi (if present)
# ------------------------------------------------------------
sed -i -e '/CONFIG_MAKE_TOOLCHAIN=y/d' configs/rockchip/01-nanopi 2>/dev/null || true
sed -i -e 's/CONFIG_IB=y/# CONFIG_IB is not set/g' configs/rockchip/01-nanopi 2>/dev/null || true
sed -i -e 's/CONFIG_SDK=y/# CONFIG_SDK is not set/g' configs/rockchip/01-nanopi 2>/dev/null || true

# ------------------------------------------------------------
# 3. Determine build type from .current_config.mk
# ------------------------------------------------------------
BUILD_TYPE="non-docker"
if [ -f .current_config.mk ]; then
    CONFIG_LINE=$(grep '^TARGET_FRIENDLYWRT_CONFIG=' .current_config.mk || true)
    if [[ "$CONFIG_LINE" == *"-docker"* ]]; then
        BUILD_TYPE="docker"
    fi
fi
echo "Build type detected: $BUILD_TYPE"

# ------------------------------------------------------------
# 4. Define core system packages (always included)
# ------------------------------------------------------------
CORE_PKGS="
luci
luci-app-firewall
luci-app-package-manager
luci-ssl-openssl
ca-certificates
openwrt-keyring
curl
firewall4
dnsmasq-full
dnsmasq_full_dhcpv6
dnsmasq_full_nftset
ppp
ppp-mod-pppoe
luci-proto-ppp
odhcp6c
odhcpd-ipv6only
luci-proto-ipv6
zram-swap
luci-theme-bootstrap
"

# ------------------------------------------------------------
# 5. User-defined packages (from original ENSURE_PKGS)
# ------------------------------------------------------------
USER_PKGS="
bc vsftpd sudo unzip file procd logrotate coreutils-stat lsof jq wireguard-tools python3-light
"

# ------------------------------------------------------------
# 6. Docker packages (only if build type is docker)
# ------------------------------------------------------------
DOCKER_PKGS=""
if [ "$BUILD_TYPE" = "docker" ]; then
    DOCKER_PKGS="docker-ce dockerd luci-app-dockerman"
fi

# ------------------------------------------------------------
# 7. Clashoo packages (always)
# ------------------------------------------------------------
CLASHOO_PKGS="
clashoo
luci-app-clashoo
luci-i18n-clashoo-zh-cn
kmod-inet-diag
"

# Merge all packages into one list
ALL_PKGS="$CORE_PKGS $USER_PKGS $DOCKER_PKGS $CLASHOO_PKGS"

# ------------------------------------------------------------
# 8. Write all packages to configs/rockchip/01-nanopi
# ------------------------------------------------------------
CONFIG_FILE="configs/rockchip/01-nanopi"
for pkg in $ALL_PKGS; do
    grep -q "CONFIG_PACKAGE_${pkg}=y" "$CONFIG_FILE" || echo "CONFIG_PACKAGE_${pkg}=y" >> "$CONFIG_FILE"
done

# ------------------------------------------------------------
# 9. Init feeds.conf and add Clashoo feed
# ------------------------------------------------------------
(cd friendlywrt && { [ ! -f feeds.conf ] && cp feeds.conf.default feeds.conf; })

FEED_CONF="friendlywrt/feeds.conf"
grep -q "src-git clashoo" "$FEED_CONF" || echo "src-git clashoo https://github.com/kenzok8/openwrt-clashoo.git;main" >> "$FEED_CONF"

# ------------------------------------------------------------
# 10. Update Clashoo feed
# ------------------------------------------------------------
(cd friendlywrt && ./scripts/feeds update clashoo && ./scripts/feeds install -a -p clashoo)

# ------------------------------------------------------------
# 11. Enable kernel INET_DIAG options (required by Clashoo)
# ------------------------------------------------------------
cd friendlywrt
KERNEL_VERSION=$(grep '^KERNEL_PATCHVER' target/linux/rockchip/Makefile | awk '{print $3}')
[ -z "$KERNEL_VERSION" ] && KERNEL_VERSION="6.1"
KERNEL_CONFIG_FILE="target/linux/rockchip/config-${KERNEL_VERSION}"
touch "$KERNEL_CONFIG_FILE"
for opt in CONFIG_INET_DIAG CONFIG_INET_TCP_DIAG CONFIG_INET_UDP_DIAG CONFIG_INET_RAW_DIAG; do
    sed -i "/^# ${opt} is not set/d" "$KERNEL_CONFIG_FILE"
    echo "${opt}=y" >> "$KERNEL_CONFIG_FILE"
done
cd ..

# ------------------------------------------------------------
# 12. UCI defaults for side-router
# ------------------------------------------------------------
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

# ------------------------------------------------------------
# 13. Enter build directory and configure
# ------------------------------------------------------------
cd friendlywrt

# Disable global options that pull unwanted packages
for opt in CONFIG_ALL_KMODS CONFIG_ALL_NONSHARED CONFIG_DEVEL CONFIG_BUILDBOT; do
    sed -i "s/^${opt}=.*/# ${opt} is not set/" .config || echo "# ${opt} is not set" >> .config
done

make defconfig

# ------------------------------------------------------------
# 14. Explicitly disable a few specific packages (double safety)
# ------------------------------------------------------------
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
luci-app-watchcat
"

for pkg in $DISABLE_PKGS; do
    sed -i "s/^CONFIG_PACKAGE_${pkg}=.*/# CONFIG_PACKAGE_${pkg} is not set/" .config
    grep -q "^# CONFIG_PACKAGE_${pkg} is not set" .config || echo "# CONFIG_PACKAGE_${pkg} is not set" >> .config
done

# ------------------------------------------------------------
# 15. Force-enable all required packages
# ------------------------------------------------------------
ENSURE_PKGS="$CORE_PKGS $USER_PKGS $DOCKER_PKGS $CLASHOO_PKGS"
for pkg in $ENSURE_PKGS; do
    sed -i "/^# CONFIG_PACKAGE_${pkg} is not set/d" .config
    sed -i "s/^CONFIG_PACKAGE_${pkg}=.*/CONFIG_PACKAGE_${pkg}=y/" .config
    grep -q "^CONFIG_PACKAGE_${pkg}=y" .config || echo "CONFIG_PACKAGE_${pkg}=y" >> .config
done

# ------------------------------------------------------------
# 16. Double-check Clashoo packages
# ------------------------------------------------------------
for pass in 1 2; do
    for pkg in clashoo luci-app-clashoo luci-i18n-clashoo-zh-cn kmod-inet-diag; do
        sed -i "/^# CONFIG_PACKAGE_${pkg} is not set/d" .config
        sed -i "/^CONFIG_PACKAGE_${pkg}=/d" .config
        echo "CONFIG_PACKAGE_${pkg}=y" >> .config
    done
done

# ------------------------------------------------------------
# 17. Verify Clashoo packages
# ------------------------------------------------------------
echo "=== Verifying Clashoo packages ==="
MISSING=0
for pkg in clashoo luci-app-clashoo luci-i18n-clashoo-zh-cn kmod-inet-diag; do
    if grep -q "^CONFIG_PACKAGE_${pkg}=y" .config; then
        echo "[OK] CONFIG_PACKAGE_${pkg}=y"
    else
        echo "[FAIL] CONFIG_PACKAGE_${pkg} not enabled"
        MISSING=1
    fi
done
[ $MISSING -eq 1 ] && { echo "ERROR: Clashoo packages missing, aborting."; exit 1; }

# ------------------------------------------------------------
# 18. Print final status
# ------------------------------------------------------------
echo "=== Final package status ==="
check_pkg() {
    grep -q "^CONFIG_PACKAGE_$1=y" .config && echo "  [ENABLED]  $1" || echo "  [DISABLED] $1"
}
echo "--- ENABLED ---"
for pkg in $ENSURE_PKGS; do check_pkg "$pkg"; done
echo "--- DISABLED ---"
for pkg in $DISABLE_PKGS; do check_pkg "$pkg"; done

cd ..
echo "All configurations applied and verified."