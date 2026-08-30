#!/bin/bash
set -e

# ========== 1. 彻底清理所有 configs/rockchip/* 中的用户空间包 ==========
echo "=== Cleaning all configs/rockchip/* of non-kmod packages ==="
for config_file in configs/rockchip/*; do
    [ -f "$config_file" ] || continue
    # 删除所有非 kmod- 开头的包配置行（=y 或 =m）
    sed -i -e '/^CONFIG_PACKAGE_kmod-/! { /^CONFIG_PACKAGE_.*=[ym]$/d; }' "$config_file"
    # 删除所有 # CONFIG_PACKAGE_xxx is not set 行（禁用行不影响大小，但保持整洁）
    sed -i -e '/^# CONFIG_PACKAGE_.* is not set$/d' "$config_file"
    echo "  Cleaned $config_file"
done

# ========== 2. 添加核心必要组件（写入 01-nanopi） ==========
CONFIG_FILE="configs/rockchip/01-nanopi"
CORE_PKGS="
ca-certificates
luci
luci-app-firewall
luci-app-package-manager
luci-ssl-openssl
openwrt-keyring
curl
"
for pkg in $CORE_PKGS; do
    grep -q "CONFIG_PACKAGE_${pkg}=y" "$CONFIG_FILE" || echo "CONFIG_PACKAGE_${pkg}=y" >> "$CONFIG_FILE"
done

# IPv6 支持（旁路由建议保留）
grep -q "CONFIG_IPV6=y" "$CONFIG_FILE" || echo "CONFIG_IPV6=y" >> "$CONFIG_FILE"

# ========== 3. 添加 Clashoo feed ==========
FEED_CONF="friendlywrt/feeds.conf"
(cd friendlywrt && { [ ! -f feeds.conf ] && cp feeds.conf.default feeds.conf; })
grep -q "src-git clashoo" "$FEED_CONF" || echo "src-git clashoo https://github.com/kenzok8/openwrt-clashoo.git;main" >> "$FEED_CONF"

# ========== 4. 添加 Clashoo 配置 ==========
grep -q "CONFIG_PACKAGE_luci-app-clashoo" "$CONFIG_FILE" || cat >> "$CONFIG_FILE" << EOF

# Clashoo packages
CONFIG_PACKAGE_clashoo=y
CONFIG_PACKAGE_luci-app-clashoo=y
CONFIG_PACKAGE_luci-i18n-clashoo-zh-cn=y
CONFIG_PACKAGE_kmod-inet-diag=y
EOF

# ========== 5. 您的自定义软件包 ==========
ENSURE_PKGS="
bc vsftpd sudo unzip file procd logrotate coreutils-stat lsof jq wireguard-tools python3-light
"
for pkg in $ENSURE_PKGS; do
    grep -q "CONFIG_PACKAGE_${pkg}=y" "$CONFIG_FILE" || echo "CONFIG_PACKAGE_${pkg}=y" >> "$CONFIG_FILE"
done

# ========== 6. 更新 Clashoo feed ==========
(cd friendlywrt && ./scripts/feeds update clashoo && ./scripts/feeds install -a -p clashoo)

# ========== 7. 修改内核配置，启用 INET_DIAG ==========
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

# ========== 8. UCI defaults for side-router ==========
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

# ========== 9. 进入构建目录，执行 defconfig 与包管理 ==========
cd friendlywrt

# 禁用全局选项（防止拉入过多包）
for opt in CONFIG_ALL_KMODS CONFIG_ALL_NONSHARED CONFIG_DEVEL CONFIG_BUILDBOT CONFIG_ALL; do
    sed -i "s/^${opt}=.*/# ${opt} is not set/" .config || echo "# ${opt} is not set" >> .config
done

echo "=== Running make defconfig ==="
make defconfig

# 统计清理前后包数量（调试）
echo "=== Package count before forced enable/disable ==="
echo "Enabled packages in .config: $(grep -c '^CONFIG_PACKAGE_.*=y' .config || echo 0)"

# ========== 10. 禁用不需要的包 ==========
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

# ========== 11. 强制启用所有需要的包（核心 + 自定义 + Clashoo） ==========
ALL_ENABLE="$CORE_PKGS $ENSURE_PKGS clashoo luci-app-clashoo luci-i18n-clashoo-zh-cn kmod-inet-diag"
for pkg in $ALL_ENABLE; do
    sed -i "/^# CONFIG_PACKAGE_${pkg} is not set/d" .config
    sed -i "s/^CONFIG_PACKAGE_${pkg}=.*/CONFIG_PACKAGE_${pkg}=y/" .config
    grep -q "^CONFIG_PACKAGE_${pkg}=y" .config || echo "CONFIG_PACKAGE_${pkg}=y" >> .config
done

# 二次确保 Clashoo 包不被依赖覆盖
for pkg in clashoo luci-app-clashoo luci-i18n-clashoo-zh-cn kmod-inet-diag; do
    sed -i "/^# CONFIG_PACKAGE_${pkg} is not set/d" .config
    sed -i "/^CONFIG_PACKAGE_${pkg}=/d" .config
    echo "CONFIG_PACKAGE_${pkg}=y" >> .config
done

make oldconfig

# ========== 12. 最终包数量统计 ==========
echo "=== Final package count ==="
echo "Enabled packages in .config: $(grep -c '^CONFIG_PACKAGE_.*=y' .config || echo 0)"

# ========== 13. 验证 ==========
echo "=== Verifying Clashoo packages ==="
for pkg in clashoo luci-app-clashoo luci-i18n-clashoo-zh-cn kmod-inet-diag; do
    if grep -q "^CONFIG_PACKAGE_${pkg}=y" .config; then
        echo "[OK] CONFIG_PACKAGE_${pkg}=y"
    else
        echo "[FAIL] CONFIG_PACKAGE_${pkg} not enabled"
        exit 1
    fi
done

echo "=== Final package status (selected) ==="
check_pkg() {
    grep -q "^CONFIG_PACKAGE_$1=y" .config && echo "  [ENABLED]  $1" || echo "  [DISABLED] $1"
}
echo "--- ENABLED (core + custom + Clashoo) ---"
for pkg in $CORE_PKGS $ENSURE_PKGS clashoo luci-app-clashoo luci-i18n-clashoo-zh-cn kmod-inet-diag; do
    check_pkg "$pkg"
done
echo "--- DISABLED (unwanted) ---"
for pkg in $DISABLE_PKGS; do
    check_pkg "$pkg"
done

cd ..
echo "All configurations applied and verified."