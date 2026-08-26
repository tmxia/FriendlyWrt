#!/bin/bash
set -e

# Ensure feeds.conf exists
(cd friendlywrt && { [ ! -f feeds.conf ] && cp feeds.conf.default feeds.conf; })

# Add Clashoo feed
FEED_CONF="friendlywrt/feeds.conf"
grep -q "src-git clashoo" "$FEED_CONF" || echo "src-git clashoo https://github.com/kenzok8/openwrt-clashoo.git;main" >> "$FEED_CONF"

# Add Clashoo packages to config file
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
bc vsftpd sudo unzip file procd logrotate coreutils-stat lsof jq wireguard-tools python3-light
"

# Write ensure packages to config file
for pkg in $ENSURE_PKGS; do
    grep -q "CONFIG_PACKAGE_${pkg}=y" "$CONFIG_FILE" || echo "CONFIG_PACKAGE_${pkg}=y" >> "$CONFIG_FILE"
done

# Update Clashoo feed
(cd friendlywrt && ./scripts/feeds update clashoo && ./scripts/feeds install -a -p clashoo)

# UCI defaults for side-router
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

# Enter build dir
cd friendlywrt

# Disable global options
for opt in CONFIG_ALL_KMODS CONFIG_ALL_NONSHARED CONFIG_DEVEL CONFIG_BUILDBOT; do
    sed -i "s/^${opt}=.*/# ${opt} is not set/" .config || echo "# ${opt} is not set" >> .config
done

# ---------- 内核选项注入（使用 scripts/config 工具） ----------
make defconfig

# 编译 scripts/config 工具
make scripts/config

# 启用所有 DIAG 相关选项
./scripts/config --file .config --enable CONFIG_SOCK_DIAG
./scripts/config --file .config --enable CONFIG_INET_DIAG
./scripts/config --file .config --enable CONFIG_INET_TCP_DIAG
./scripts/config --file .config --enable CONFIG_INET_UDP_DIAG
./scripts/config --file .config --enable CONFIG_INET_RAW_DIAG
./scripts/config --file .config --enable CONFIG_INET_DIAG_DESTROY

# 同步配置（非交互式）
make olddefconfig

# 验证内核选项
echo "=== Kernel config check ==="
for opt in CONFIG_SOCK_DIAG CONFIG_INET_DIAG CONFIG_INET_DIAG_DESTROY; do
    if grep -q "^$opt=y" .config; then
        echo "  [OK] $opt=y"
    else
        echo "  [FAIL] $opt not set"
        # 再次尝试用 scripts/config 强制启用
        ./scripts/config --file .config --enable "$opt"
    fi
done
# 重新同步（如有改动）
if grep -q "CONFIG_INET_DIAG=y" .config; then
    make olddefconfig
    echo "  Kernel options successfully enabled."
else
    echo "  WARNING: Kernel options may not be fully enabled, but continuing..."
fi
# ------------------------------------------------------------

# Packages to disable
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

# Force disable unwanted packages
for pkg in $DISABLE_PKGS; do
    sed -i "s/^CONFIG_PACKAGE_${pkg}=.*/# CONFIG_PACKAGE_${pkg} is not set/" .config
    grep -q "^# CONFIG_PACKAGE_${pkg} is not set" .config || echo "# CONFIG_PACKAGE_${pkg} is not set" >> .config
done

# Force enable required packages
for pkg in $ENSURE_PKGS; do
    sed -i "/^# CONFIG_PACKAGE_${pkg} is not set/d" .config
    sed -i "s/^CONFIG_PACKAGE_${pkg}=.*/CONFIG_PACKAGE_${pkg}=y/" .config
    grep -q "^CONFIG_PACKAGE_${pkg}=y" .config || echo "CONFIG_PACKAGE_${pkg}=y" >> .config
done

# Ensure Clashoo packages are enabled
for pkg in clashoo luci-app-clashoo luci-i18n-clashoo-zh-cn kmod-inet-diag; do
    sed -i "/^# CONFIG_PACKAGE_${pkg} is not set/d" .config
    sed -i "s/^CONFIG_PACKAGE_${pkg}=.*/CONFIG_PACKAGE_${pkg}=y/" .config
    grep -q "^CONFIG_PACKAGE_${pkg}=y" .config || echo "CONFIG_PACKAGE_${pkg}=y" >> .config
done

# Final sync (to capture any dependency changes from package selections)
make olddefconfig

# Print final status
echo "=== Final package status ==="
check_pkg() {
    grep -q "^CONFIG_PACKAGE_$1=y" .config && echo "  [ENABLED]  $1" || echo "  [DISABLED] $1"
}
echo "--- ENABLED ---"
for pkg in $ENSURE_PKGS; do check_pkg "$pkg"; done
echo "--- DISABLED ---"
for pkg in $DISABLE_PKGS; do check_pkg "$pkg"; done

cd ..
echo "All configurations applied."