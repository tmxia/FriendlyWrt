#!/bin/bash

set -e

# ---- 0.确保 feeds.conf  ----
(cd friendlywrt && {
    [ ! -f feeds.conf ] && cp feeds.conf.default feeds.conf
    echo "feeds.conf initialized"
})

# ---- 1.添加 Clashoo feed ----
FEED_CONF="friendlywrt/feeds.conf"
if ! grep -q "src-git clashoo" "$FEED_CONF"; then
    echo "src-git clashoo https://github.com/kenzok8/openwrt-clashoo.git;main" >> "$FEED_CONF"
    echo "Added Clashoo feed to feeds.conf"
fi

# ---- 2.添加Clashoo编译配置 ----
CONFIG_FILE="configs/rockchip/01-nanopi"
if ! grep -q "CONFIG_PACKAGE_luci-app-clashoo" "$CONFIG_FILE"; then
    cat >> "$CONFIG_FILE" << EOF

# Clashoo packages
CONFIG_PACKAGE_clashoo=y
CONFIG_PACKAGE_luci-app-clashoo=y
CONFIG_PACKAGE_luci-i18n-clashoo-zh-cn=y
CONFIG_PACKAGE_kmod-inet-diag=y
EOF
    echo "Added Clashoo config to $CONFIG_FILE"
fi

# ================== 添加软件包列表 ==================
ENSURE_PKGS="
    bc
    vsftpd
    openssh-sftp-server
    wget-ssl
    busybox
    sudo
    unzip
    file
    procd
    logrotate
    coreutils-stat
    lsof
    jq
    wireguard-tools
    python3-light
    cpufrequtils
    netdata
    luci-app-cpufreq
    luci-app-netdata
    luci-theme-bootstrap
"
# 如需增加其他包，直接在上面列表中添加即可。

# ---- 3.将上述包写入 configs/rockchip/01-nanopi ----
for pkg in $ENSURE_PKGS; do
    if ! grep -q "CONFIG_PACKAGE_${pkg}=y" "$CONFIG_FILE"; then
        echo "CONFIG_PACKAGE_${pkg}=y" >> "$CONFIG_FILE"
        echo "Added CONFIG_PACKAGE_${pkg}=y to $CONFIG_FILE"
    fi
done

# ---- 4.更新 feeds ----
(cd friendlywrt && ./scripts/feeds update clashoo)
(cd friendlywrt && ./scripts/feeds install -a -p clashoo)

# ---- 5.移除 kmod-inet-diag 依赖（Clashoo） ----
if [ -d friendlywrt/feeds/clashoo ]; then
    find friendlywrt/feeds/clashoo -name "Makefile" -exec sed -i 's/+kmod-inet-diag//g' {} \;
    echo "Removed kmod-inet-diag dependency from Clashoo Makefile(s)"
else
    echo "Warning: Clashoo feed directory not found, skip dependency fix"
fi

# ---- 6.植入旁路由预配置及主题切换 ----
mkdir -p friendlywrt/files/etc/uci-defaults
cat > friendlywrt/files/etc/uci-defaults/99-custom << 'EOF'
#!/bin/sh
# 旁路由固定IP配置
uci set network.lan.ipaddr='192.168.3.3'
uci set network.lan.gateway='192.168.3.1'
uci set network.lan.dns='192.168.3.1'
uci commit network

# 禁用LAN口DHCP
uci set dhcp.lan.ignore='1'
uci commit dhcp

# 更改root密码
echo -e "tony\ntony" | passwd root > /dev/null 2>&1

# 设置主题为Bootstrap
uci set luci.main.mediaurlbase='/luci-static/bootstrap'
uci delete luci.themes.Argon 2>/dev/null || true
uci commit luci

rm -rf /tmp/luci-* /tmp/luci-modulecache/* 2>/dev/null || true

exit 0
EOF
chmod +x friendlywrt/files/etc/uci-defaults/99-custom
echo "Added custom uci-defaults for preset configuration, password, Bootstrap theme, and extra packages"

# ================== 禁用与强制启用 ==================
cd friendlywrt

# ---- 7. 禁用全局选项 ----
sed -i 's/^CONFIG_ALL_KMODS=.*/# CONFIG_ALL_KMODS is not set/' .config || echo "# CONFIG_ALL_KMODS is not set" >> .config
sed -i 's/^CONFIG_ALL_NONSHARED=.*/# CONFIG_ALL_NONSHARED is not set/' .config || echo "# CONFIG_ALL_NONSHARED is not set" >> .config
sed -i 's/^CONFIG_DEVEL=.*/# CONFIG_DEVEL is not set/' .config || echo "# CONFIG_DEVEL is not set" >> .config
sed -i 's/^CONFIG_BUILDBOT=.*/# CONFIG_BUILDBOT is not set/' .config || echo "# CONFIG_BUILDBOT is not set" >> .config

# ---- 8. 生成初始配置 ----
make defconfig

# ---- 9. 定义需要禁用的包列表 ----
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
# 如需保留 IPv6，请删除 odhcp6c odhcpd-ipv6only luci-proto-ipv6

# ---- 10. 禁用所有不需要的包 ----
for pkg in $DISABLE_PKGS; do
    sed -i "s/^CONFIG_PACKAGE_${pkg}=.*/# CONFIG_PACKAGE_${pkg} is not set/" .config
    grep -q "^# CONFIG_PACKAGE_${pkg} is not set" .config || echo "# CONFIG_PACKAGE_${pkg} is not set" >> .config
done

# ---- 11. 强制启用所有需要的包 ----
for pkg in $ENSURE_PKGS; do
    sed -i "/^# CONFIG_PACKAGE_${pkg} is not set/d" .config
    sed -i "s/^CONFIG_PACKAGE_${pkg}=.*/CONFIG_PACKAGE_${pkg}=y/" .config
    grep -q "^CONFIG_PACKAGE_${pkg}=y" .config || echo "CONFIG_PACKAGE_${pkg}=y" >> .config
done

# ---- 12. 应用所有修改 ----
make oldconfig

# ---- 13. 打印所有定义的包状态 ----
echo "=== Final package status (auto-generated from lists) ==="

check_pkg() {
    local pkg="$1"
    if grep -q "^CONFIG_PACKAGE_${pkg}=y" .config; then
        echo "  [ENABLED]  $pkg"
    elif grep -q "^# CONFIG_PACKAGE_${pkg} is not set" .config; then
        echo "  [DISABLED] $pkg"
    else
        echo "  [UNKNOWN]  $pkg (not found)"
    fi
}

echo "--- Packages to ENABLE (from ENSURE_PKGS) ---"
for pkg in $ENSURE_PKGS; do
    check_pkg "$pkg"
done

echo "--- Packages to DISABLE (from DISABLE_PKGS) ---"
for pkg in $DISABLE_PKGS; do
    check_pkg "$pkg"
done

cd ..

echo "All configurations applied in one pass."