#!/bin/bash
set -e

# ========== 1. 删除多余的配置文件（除 01-nanopi 外） ==========
echo "=== Removing all configs/rockchip/* except 01-nanopi ==="
for config_file in configs/rockchip/*; do
    [ -f "$config_file" ] || continue
    filename=$(basename "$config_file")
    if [ "$filename" != "01-nanopi" ]; then
        rm -f "$config_file"
        echo "  Removed $config_file"
    fi
done

# ========== 2. 清理 01-nanopi 中的包配置行，保留其他配置 ==========
CONFIG_FILE="configs/rockchip/01-nanopi"
# 删除所有 CONFIG_PACKAGE_* 行（启用和禁用）
sed -i -e '/^CONFIG_PACKAGE_/d' -e '/^# CONFIG_PACKAGE_.* is not set$/d' "$CONFIG_FILE"

# ========== 3. 添加核心必要组件（LuCI、防火墙等） ==========
CORE_PKGS="
ca-certificates
luci
luci-app-firewall
luci-app-package-manager
luci-ssl-openssl
openwrt-keyring
curl
luci-i18n-base-zh-cn
"
for pkg in $CORE_PKGS; do
    echo "CONFIG_PACKAGE_${pkg}=y" >> "$CONFIG_FILE"
done

# ========== 4. 添加 Clashoo feed ==========
FEED_CONF="friendlywrt/feeds.conf"
(cd friendlywrt && { [ ! -f feeds.conf ] && cp feeds.conf.default feeds.conf; })
grep -q "src-git clashoo" "$FEED_CONF" || echo "src-git clashoo https://github.com/kenzok8/openwrt-clashoo.git;main" >> "$FEED_CONF"

# ========== 5. 添加 Clashoo 包 ==========
cat >> "$CONFIG_FILE" << 'EOF'
CONFIG_PACKAGE_clashoo=y
CONFIG_PACKAGE_luci-app-clashoo=y
CONFIG_PACKAGE_luci-i18n-clashoo-zh-cn=y
CONFIG_PACKAGE_kmod-inet-diag=y
EOF

# ========== 6. 您的自定义软件包 ==========
ENSURE_PKGS="
bc vsftpd sudo unzip file procd logrotate coreutils-stat lsof jq wireguard-tools python3-light
"
for pkg in $ENSURE_PKGS; do
    echo "CONFIG_PACKAGE_${pkg}=y" >> "$CONFIG_FILE"
done

# ========== 7. 更新 Clashoo feed ==========
(cd friendlywrt && ./scripts/feeds update clashoo && ./scripts/feeds install -a -p clashoo)

# ========== 8. 修改内核配置，启用 INET_DIAG ==========
cd friendlywrt
KERNEL_VERSION=$(grep '^KERNEL_PATCHVER' target/linux/rockchip/Makefile | awk '{print $3}')
[ -z "$KERNEL_VERSION" ] && KERNEL_VERSION="6.1"
KERNEL_CONFIG_FILE="target/linux/rockchip/config-${KERNEL_VERSION}"
touch "$KERNEL_CONFIG_FILE"
for opt in INET_DIAG INET_TCP_DIAG INET_UDP_DIAG INET_RAW_DIAG; do
    sed -i "/^# CONFIG_${opt} is not set/d" "$KERNEL_CONFIG_FILE"
    grep -q "^CONFIG_${opt}=y" "$KERNEL_CONFIG_FILE" || echo "CONFIG_${opt}=y" >> "$KERNEL_CONFIG_FILE"
done
echo "Kernel config updated: $KERNEL_CONFIG_FILE"
cd ..

# ========== 9. UCI defaults for side-router ==========
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

# ========== 10. 进入构建目录，执行配置 ==========
cd friendlywrt

# 禁用全局选项（防止拉入过多包）
for opt in CONFIG_ALL_KMODS CONFIG_ALL_NONSHARED CONFIG_DEVEL CONFIG_BUILDBOT CONFIG_ALL; do
    sed -i "s/^${opt}=.*/# ${opt} is not set/" .config || echo "# ${opt} is not set" >> .config
done

# 确保目标平台配置完整（01-nanopi 中已有，无需额外操作）
make defconfig

# ========== 11. 禁用不需要的包 ==========
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

# ========== 12. 强制启用所有需要的包 ==========
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

# ========== 13. 验证 ==========
echo "=== Final package count ==="
echo "Enabled packages in .config: $(grep -c '^CONFIG_PACKAGE_.*=y' .config || echo 0)"

echo "=== Verifying Clashoo packages ==="
for pkg in clashoo luci-app-clashoo luci-i18n-clashoo-zh-cn kmod-inet-diag; do
    if grep -q "^CONFIG_PACKAGE_${pkg}=y" .config; then
        echo "[OK] CONFIG_PACKAGE_${pkg}=y"
    else
        echo "[FAIL] CONFIG_PACKAGE_${pkg} not enabled"
        exit 1
    fi
done

echo "=== Final package status ==="
check_pkg() {
    grep -q "^CONFIG_PACKAGE_$1=y" .config && echo "  [ENABLED]  $1" || echo "  [DISABLED] $1"
}
echo "--- ENABLED ---"
for pkg in $CORE_PKGS $ENSURE_PKGS clashoo luci-app-clashoo luci-i18n-clashoo-zh-cn kmod-inet-diag; do
    check_pkg "$pkg"
done
echo "--- DISABLED ---"
for pkg in $DISABLE_PKGS; do
    check_pkg "$pkg"
done

cd ..
echo "All configurations applied and verified."