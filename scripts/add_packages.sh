#!/bin/bash
set -e

# ---- 1. 定位并进入 project/ 目录 ----
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$SCRIPT_DIR/../project"
cd "$PROJECT_DIR" || { echo "project directory not found at $PROJECT_DIR"; exit 1; }

# ---- 2. 定义自定义配置文件（不修改 01-nanopi） ----
CUSTOM_CONFIG="configs/rockchip/03-custom"
# 清空或创建该文件
> "$CUSTOM_CONFIG"

# ---- 3. 辅助函数：启用包 ----
add_pkg() {
    local pkg="$1"
    sed -i "/^# CONFIG_PACKAGE_${pkg} is not set/d" "$CUSTOM_CONFIG"
    sed -i "/^CONFIG_PACKAGE_${pkg}=/d" "$CUSTOM_CONFIG"
    echo "CONFIG_PACKAGE_${pkg}=y" >> "$CUSTOM_CONFIG"
    echo "Enabled CONFIG_PACKAGE_${pkg}"
}

# ---- 4. 辅助函数：禁用包 ----
disable_pkg() {
    local pkg="$1"
    sed -i "/^CONFIG_PACKAGE_${pkg}=/d" "$CUSTOM_CONFIG"
    sed -i "/^# CONFIG_PACKAGE_${pkg} is not set/d" "$CUSTOM_CONFIG"
    echo "# CONFIG_PACKAGE_${pkg} is not set" >> "$CUSTOM_CONFIG"
    echo "Disabled CONFIG_PACKAGE_${pkg}"
}

# ========== 5. 添加 Clashoo 相关配置 ==========
add_pkg "clashoo"
add_pkg "luci-app-clashoo"
add_pkg "luci-i18n-clashoo-zh-cn"
add_pkg "kmod-inet-diag"

# ========== 6. 添加额外软件包 ==========
EXTRA_PKGS="bc vsftpd openssh-sftp-server wget-ssl busybox sudo unzip file procd logrotate coreutils-stat lsof"
for pkg in $EXTRA_PKGS; do
    add_pkg "$pkg"
done

add_pkg "cpufrequtils"
add_pkg "netdata"
add_pkg "luci-app-cpufreq"
add_pkg "luci-app-netdata"
add_pkg "ca-certificates-nonfree"
add_pkg "luci-theme-bootstrap"

# ========== 7. 禁用旁路由不需要的功能包 ==========
echo "Disabling unnecessary packages for side-router..."

# 按用户要求关闭 Adblock 和 Aria2
disable_pkg "adblock"
disable_pkg "luci-app-adblock"
disable_pkg "aria2"
disable_pkg "aria2-openssl"
disable_pkg "luci-app-aria2"

# 其他不必要功能
DISABLE_LIST="
    sqm-scripts luci-app-sqm
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
    # 若不需 IPv6 可取消注释以下三行
    # odhcp6c odhcpd-ipv6only luci-proto-ipv6
"

for pkg in $DISABLE_LIST; do
    disable_pkg "$pkg"
done

# ========== 8. 进入 friendlywrt 目录进行后续操作 ==========
cd friendlywrt || { echo "friendlywrt directory not found"; exit 1; }

# ---- 8.1 确保 feeds.conf 包含 Clashoo ----
FEED_CONF="feeds.conf"
if ! grep -q "src-git clashoo" "$FEED_CONF"; then
    echo "src-git clashoo https://github.com/kenzok8/openwrt-clashoo.git;main" >> "$FEED_CONF"
    echo "Added Clashoo feed to feeds.conf"
fi

# ---- 8.2 更新所有 feeds ----
echo "Updating all feeds..."
./scripts/feeds update -a
./scripts/feeds install -a

# ---- 8.3 修复依赖问题 ----
# 移除 kmod-inet-diag 依赖（Clashoo）
if [ -d feeds/clashoo ]; then
    find feeds/clashoo -name "Makefile" -exec sed -i 's/+kmod-inet-diag//g' {} \;
    echo "Removed kmod-inet-diag dependency from Clashoo Makefile(s)"
else
    echo "Warning: Clashoo feed directory not found, skip dependency fix"
fi

# 修正 luci-app-cpufreq 依赖 (cpufreq -> cpufrequtils)
if [ -d feeds/luci/applications/luci-app-cpufreq ]; then
    sed -i 's/+cpufreq/+cpufrequtils/g' feeds/luci/applications/luci-app-cpufreq/Makefile
    echo "Fixed luci-app-cpufreq dependency (cpufreq -> cpufrequtils)"
fi

# 修正 luci-app-netdata 依赖 (netdata-ssl -> netdata)
if [ -d feeds/luci/applications/luci-app-netdata ]; then
    sed -i 's/+netdata-ssl/+netdata/g' feeds/luci/applications/luci-app-netdata/Makefile
    echo "Fixed luci-app-netdata dependency (netdata-ssl -> netdata)"
fi

# ---- 8.4 重新生成 .config 以合并所有配置修改 ----
echo "Running make defconfig to merge configurations..."
make defconfig
make oldconfig

# ---- 8.5 植入旁路由预配置及主题切换（uci-defaults） ----
mkdir -p files/etc/uci-defaults
cat > files/etc/uci-defaults/99-custom << 'EOF'
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
chmod +x files/etc/uci-defaults/99-custom
echo "Added custom uci-defaults for preset configuration, password, Bootstrap theme, and extra packages"

echo "All package configurations and customizations applied successfully."