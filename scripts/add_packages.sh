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

# ---- 内核配置注入（双保险） ----
# 1. 修改 OpenWrt 内核配置文件，使 defconfig 直接包含
KERNEL_CONFIG="target/linux/rockchip/config-6.1"
mkdir -p "$(dirname "$KERNEL_CONFIG")"
if ! grep -q "CONFIG_SOCK_DIAG=y" "$KERNEL_CONFIG" 2>/dev/null; then
    cat >> "$KERNEL_CONFIG" << EOF
CONFIG_SOCK_DIAG=y
CONFIG_INET_DIAG=y
CONFIG_INET_TCP_DIAG=y
CONFIG_INET_UDP_DIAG=y
CONFIG_INET_RAW_DIAG=y
CONFIG_INET_DIAG_DESTROY=y
EOF
fi

# 2. 生成初始 .config
make defconfig

# 3. 强制在 .config 中启用（防止合并失败或覆盖）
KERNEL_OPTS="
CONFIG_SOCK_DIAG=y
CONFIG_INET_DIAG=y
CONFIG_INET_TCP_DIAG=y
CONFIG_INET_UDP_DIAG=y
CONFIG_INET_RAW_DIAG=y
CONFIG_INET_DIAG_DESTROY=y
"
for opt in $KERNEL_OPTS; do
    key="${opt%=*}"
    val="${opt#*=}"
    sed -i "/^# $key is not set/d" .config
    sed -i "/^$key=/d" .config
    echo "$opt" >> .config
done

# 4. 使用 oldconfig 解析依赖（优先 olddefconfig，失败则 oldconfig）
make olddefconfig 2>/dev/null || yes "" | make oldconfig

# 5. 验证内核选项状态
echo "=== Kernel config check ==="
for opt in CONFIG_SOCK_DIAG CONFIG_INET_DIAG CONFIG_INET_DIAG_DESTROY; do
    if grep -q "^$opt=y" .config; then
        echo "  [OK] $opt=y"
    else
        echo "  [FAIL] $opt not set -> forcing again"
        echo "$opt=y" >> .config
    fi
done
# 再次运行 oldconfig 以处理依赖
make olddefconfig 2>/dev/null || yes "" | make oldconfig
# 最终检查
grep -E "CONFIG_(SOCK|INET)_DIAG" .config | sort -u

# ---- 包管理（原逻辑不变） ----
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

for pkg in $ENSURE_PKGS; do
    sed -i "/^# CONFIG_PACKAGE_${pkg} is not set/d" .config
    sed -i "s/^CONFIG_PACKAGE_${pkg}=.*/CONFIG_PACKAGE_${pkg}=y/" .config
    grep -q "^CONFIG_PACKAGE_${pkg}=y" .config || echo "CONFIG_PACKAGE_${pkg}=y" >> .config
done

for pkg in clashoo luci-app-clashoo luci-i18n-clashoo-zh-cn kmod-inet-diag; do
    sed -i "/^# CONFIG_PACKAGE_${pkg} is not set/d" .config
    sed -i "s/^CONFIG_PACKAGE_${pkg}=.*/CONFIG_PACKAGE_${pkg}=y/" .config
    grep -q "^CONFIG_PACKAGE_${pkg}=y" .config || echo "CONFIG_PACKAGE_${pkg}=y" >> .config
done

# 最终同步配置
make olddefconfig 2>/dev/null || yes "" | make oldconfig

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