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

# ---- 3.添加软件包 ----
EXTRA_PKGS="bc vsftpd openssh-sftp-server wget-ssl busybox sudo unzip file procd logrotate coreutils-stat lsof jq wireguard-tools python3-light"

for pkg in $EXTRA_PKGS; do
    if ! grep -q "CONFIG_PACKAGE_${pkg}=y" "$CONFIG_FILE"; then
        echo "CONFIG_PACKAGE_${pkg}=y" >> "$CONFIG_FILE"
        echo "Added CONFIG_PACKAGE_${pkg}=y to $CONFIG_FILE"
    fi
done

# 添加 cpufrequtils 和 netdata（为 luci-app-cpufreq / luci-app-netdata 提供底层依赖）
if ! grep -q "CONFIG_PACKAGE_cpufrequtils=y" "$CONFIG_FILE"; then
    echo "CONFIG_PACKAGE_cpufrequtils=y" >> "$CONFIG_FILE"
    echo "Added CONFIG_PACKAGE_cpufrequtils=y to $CONFIG_FILE"
fi
if ! grep -q "CONFIG_PACKAGE_netdata=y" "$CONFIG_FILE"; then
    echo "CONFIG_PACKAGE_netdata=y" >> "$CONFIG_FILE"
    echo "Added CONFIG_PACKAGE_netdata=y to $CONFIG_FILE"
fi

# 添加 luci-app-cpufreq 和 luci-app-netdata 本身的配置
if ! grep -q "CONFIG_PACKAGE_luci-app-cpufreq=y" "$CONFIG_FILE"; then
    echo "CONFIG_PACKAGE_luci-app-cpufreq=y" >> "$CONFIG_FILE"
    echo "Added CONFIG_PACKAGE_luci-app-cpufreq=y to $CONFIG_FILE"
fi
if ! grep -q "CONFIG_PACKAGE_luci-app-netdata=y" "$CONFIG_FILE"; then
    echo "CONFIG_PACKAGE_luci-app-netdata=y" >> "$CONFIG_FILE"
    echo "Added CONFIG_PACKAGE_luci-app-netdata=y to $CONFIG_FILE"
fi

# ---- 4.设置默认主题 ----
if ! grep -q "CONFIG_PACKAGE_luci-theme-bootstrap=y" "$CONFIG_FILE"; then
    echo "CONFIG_PACKAGE_luci-theme-bootstrap=y" >> "$CONFIG_FILE"
    echo "Added CONFIG_PACKAGE_luci-theme-bootstrap=y to $CONFIG_FILE"
fi

# 启用非自由证书包
if ! grep -q "CONFIG_CA_CERTIFICATES_NONFREE=y" "$CONFIG_FILE"; then
    echo "CONFIG_CA_CERTIFICATES_NONFREE=y" >> "$CONFIG_FILE"
    echo "Added CONFIG_CA_CERTIFICATES_NONFREE=y to $CONFIG_FILE"
fi

# ---- 5.更新 feeds ----
(cd friendlywrt && ./scripts/feeds update clashoo)
(cd friendlywrt && ./scripts/feeds install -a -p clashoo)

# ---- 6.移除 kmod-inet-diag 依赖（Clashoo） ----
if [ -d friendlywrt/feeds/clashoo ]; then
    find friendlywrt/feeds/clashoo -name "Makefile" -exec sed -i 's/+kmod-inet-diag//g' {} \;
    echo "Removed kmod-inet-diag dependency from Clashoo Makefile(s)"
else
    echo "Warning: Clashoo feed directory not found, skip dependency fix"
fi

# ---- 7.修正 luci-app-cpufreq 和 luci-app-netdata 的依赖 ----
if [ -d friendlywrt/feeds/luci/applications/luci-app-cpufreq ]; then
    sed -i 's/+cpufreq/+cpufrequtils/g' friendlywrt/feeds/luci/applications/luci-app-cpufreq/Makefile
    echo "Fixed luci-app-cpufreq dependency (cpufreq -> cpufrequtils)"
fi

if [ -d friendlywrt/feeds/luci/applications/luci-app-netdata ]; then
    sed -i 's/+netdata-ssl/+netdata/g' friendlywrt/feeds/luci/applications/luci-app-netdata/Makefile
    echo "Fixed luci-app-netdata dependency (netdata-ssl -> netdata)"
fi

# ---- 8.植入旁路由预配置及主题切换 ----
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

# ================== 强制禁用功能包 ==================
cd friendlywrt

# 1. 先禁用全局选项，防止它们拉入不需要的包
sed -i 's/^CONFIG_ALL_KMODS=.*/# CONFIG_ALL_KMODS is not set/' .config || echo "# CONFIG_ALL_KMODS is not set" >> .config
sed -i 's/^CONFIG_ALL_NONSHARED=.*/# CONFIG_ALL_NONSHARED is not set/' .config || echo "# CONFIG_ALL_NONSHARED is not set" >> .config
sed -i 's/^CONFIG_DEVEL=.*/# CONFIG_DEVEL is not set/' .config || echo "# CONFIG_DEVEL is not set" >> .config
sed -i 's/^CONFIG_BUILDBOT=.*/# CONFIG_BUILDBOT is not set/' .config || echo "# CONFIG_BUILDBOT is not set" >> .config

# 2. 生成初始配置
make defconfig

# 3. 定义需要禁用的具体包列表
DISABLE_PKGS="
    adblock
    luci-app-adblock
    aria2
    aria2-openssl
    luci-app-aria2
    sqm-scripts
    nft-qos
    luci-app-nft-qos
    luci-app-sqm
    ddns-scripts
    luci-app-ddns
    miniupnpd
    miniupnpd-nftables
    luci-app-upnp
    samba4-libs
    samba4-server
    luci-app-samba4
    minidlna
    luci-app-minidlna
    comgt
    luci-proto-3g
    luci-proto-qmi
    qmi-utils
    uqmi
    umbim
    usb-modeswitch-official
    wwan
    iwlwifi-firmware-ax200
    iwlwifi-firmware-ax210
    rtl8822be-firmware
    rtl8822ce-firmware
    mt76x2-firmware
    mt792x-firmware
    luci-app-diskman
    collectd
    luci-app-statistics
    ppp
    ppp-mod-pppoe
    luci-proto-ppp
    luci-app-watchcat
    # 若需保留 IPv6，请删除以下三行
    odhcp6c
    odhcpd-ipv6only
    luci-proto-ipv6
"

# 4. 使用 sed 直接禁用每个包
for pkg in $DISABLE_PKGS; do
    # 将任何可能的启用行或禁用行替换为明确的禁用行
    sed -i "s/^CONFIG_PACKAGE_${pkg}=.*/# CONFIG_PACKAGE_${pkg} is not set/" .config
    # 如果该行不存在，则追加
    grep -q "^# CONFIG_PACKAGE_${pkg} is not set" .config || echo "# CONFIG_PACKAGE_${pkg} is not set" >> .config
done

# 5. 运行 oldconfig 应用修改
make oldconfig

# 6. 再次检查并强制禁用
for pkg in $DISABLE_PKGS; do
    sed -i "s/^CONFIG_PACKAGE_${pkg}=.*/# CONFIG_PACKAGE_${pkg} is not set/" .config
    grep -q "^# CONFIG_PACKAGE_${pkg} is not set" .config || echo "# CONFIG_PACKAGE_${pkg} is not set" >> .config
done
make oldconfig

# 打印关键包状态
echo "=== Final package status ==="
grep -E "CONFIG_PACKAGE_(adblock|aria2|sqm-scripts|ddns-scripts|miniupnpd|samba4|minidlna|ppp|odhcp6c)" .config || echo "All disabled packages are not set."

cd ..

echo "All unwanted packages have been forcefully disabled."