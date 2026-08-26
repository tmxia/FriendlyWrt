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

# ================== 统一维护的软件包列表（添加/启用） ==================
ENSURE_PKGS="
    bc
    vsftpd
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
    netdata
    luci-app-cpufreq
    luci-app-netdata
"
# 如需增加其他包，直接在上面列表中添加即可，脚本会自动处理。

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

# ---- 6.修正 luci-app-cpufreq 和 luci-app-netdata 的依赖 ----
if [ -d friendlywrt/feeds/luci/applications/luci-app-cpufreq ]; then
    sed -i 's/+cpufreq/+cpufrequtils/g' friendlywrt/feeds/luci/applications/luci-app-cpufreq/Makefile
    echo "Fixed luci-app-cpufreq dependency (cpufreq -> cpufrequtils)"
fi

if [ -d friendlywrt/feeds/luci/applications/luci-app-netdata ]; then
    sed -i 's/+netdata-ssl/+netdata/g' friendlywrt/feeds/luci/applications/luci-app-netdata/Makefile
    echo "Fixed luci-app-netdata dependency (netdata-ssl -> netdata)"
fi

# ---- 7.植入旁路由预配置及主题切换 ----
mkdir -p friendlywrt/files/etc/uci-defaults
cat > friendlywrt/files/etc/uci-defaults/99-custom << 'EOF'
#!/bin/sh
# 旁路由固定IP配置（兼容 OpenWrt 24.10 及 25.x）

# 1. IP 地址改用 CIDR 格式（新版 netifd 强制要求，旧版同样支持）
uci set network.lan.ipaddr='192.168.3.3/24'
uci set network.lan.gateway='192.168.3.1'
uci set network.lan.dns='192.168.3.1'
uci commit network

# 2. 禁用 LAN 口 DHCP
uci set dhcp.lan.ignore='1'
uci commit dhcp

# 3. 修改 root 密码（使用 printf 替代 echo -e，兼容性更好）
printf "tony\ntony\n" | passwd root > /dev/null 2>&1

# 4. 设置 LuCI 主题
uci set luci.main.mediaurlbase='/luci-static/bootstrap'
uci delete luci.themes.Argon 2>/dev/null || true
uci commit luci

# 5. 【新增】关闭 rp_filter，解决 25.x 内核拦截旁路由转发的关键问题（对 24.10 无副作用）
sed -i '/net.ipv4.conf.*rp_filter/d' /etc/sysctl.conf
cat >> /etc/sysctl.conf <<EOF
net.ipv4.conf.all.rp_filter=0
net.ipv4.conf.default.rp_filter=0
net.ipv4.conf.lan.rp_filter=0
EOF
sysctl -p >/dev/null 2>&1

# 6. 清理 LuCI 缓存
rm -rf /tmp/luci-* /tmp/luci-modulecache/* 2>/dev/null || true

exit 0
EOF
chmod +x friendlywrt/files/etc/uci-defaults/99-custom
echo "Added custom uci-defaults for preset configuration, password, Bootstrap theme, and extra packages"

# ================== 统一处理：禁用不需要的 + 强制启用必需的 ==================
cd friendlywrt

# ---- 8. 禁用全局选项 ----
sed -i 's/^CONFIG_ALL_KMODS=.*/# CONFIG_ALL_KMODS is not set/' .config || echo "# CONFIG_ALL_KMODS is not set" >> .config
sed -i 's/^CONFIG_ALL_NONSHARED=.*/# CONFIG_ALL_NONSHARED is not set/' .config || echo "# CONFIG_ALL_NONSHARED is not set" >> .config
sed -i 's/^CONFIG_DEVEL=.*/# CONFIG_DEVEL is not set/' .config || echo "# CONFIG_DEVEL is not set" >> .config
sed -i 's/^CONFIG_BUILDBOT=.*/# CONFIG_BUILDBOT is not set/' .config || echo "# CONFIG_BUILDBOT is not set" >> .config

# ---- 9. 生成初始配置 ----
make defconfig

# ---- 10. 定义需要禁用的包列表 ----
DISABLE_PKGS="
    adblock luci-app-adblock
    aria2 aria2-openssl luci-app-aria2
    sqm-scripts nft-qos luci-app-nft-qos luci-app-sqm
    ddns-scripts luci-app-ddns
    miniupnpd miniupnpd-nftables luci-app-upnp
    samba4-libs samba4-server luci-app-samba4
    minidlna luci-app-minidlna
    comgt luci-proto-3g luci-proto-qmi qmi-utils uqmi umbim usb-modeswitch-official wwan
    iwlwifi-firmware-ax200 iwlwifi-firmware-ax210 rtl8822be-firmware rtl8822ce-firmware mt76x2-firmware mt792x-firmware
    luci-app-diskman
    collectd luci-app-statistics
    ppp ppp-mod-pppoe luci-proto-ppp
    luci-app-watchcat
"

# ---- 11. 禁用所有不需要的包 ----
for pkg in $DISABLE_PKGS; do
    sed -i "s/^CONFIG_PACKAGE_${pkg}=.*/# CONFIG_PACKAGE_${pkg} is not set/" .config
    grep -q "^# CONFIG_PACKAGE_${pkg} is not set" .config || echo "# CONFIG_PACKAGE_${pkg} is not set" >> .config
done

# ---- 12. 强制启用所有需要的包（直接使用 ENSURE_PKGS，与步骤3一致） ----
for pkg in $ENSURE_PKGS; do
    sed -i "/^# CONFIG_PACKAGE_${pkg} is not set/d" .config
    sed -i "s/^CONFIG_PACKAGE_${pkg}=.*/CONFIG_PACKAGE_${pkg}=y/" .config
    grep -q "^CONFIG_PACKAGE_${pkg}=y" .config || echo "CONFIG_PACKAGE_${pkg}=y" >> .config
done

# ---- 13. 应用所有修改 ----
make oldconfig

# ---- 14. 自动打印所有定义的包状态（无需手动维护） ----
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