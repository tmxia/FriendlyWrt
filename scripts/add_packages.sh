#!/bin/bash
set -e

# 1. 删除多余配置文件，仅保留 01-nanopi
echo "=== Removing all configs/rockchip/* except 01-nanopi ==="
for config_file in configs/rockchip/*; do
    [ -f "$config_file" ] || continue
    filename=$(basename "$config_file")
    if [ "$filename" != "01-nanopi" ]; then
        rm -f "$config_file"
        echo "  Removed $config_file"
    fi
done

# 2. 完全重建 01-nanopi
CONFIG_FILE="configs/rockchip/01-nanopi"
> "$CONFIG_FILE"

# 3. 写入目标平台和全局禁用
cat >> "$CONFIG_FILE" << 'EOF'
# Target platform (NanoPi R5S)
CONFIG_TARGET_rockchip=y
CONFIG_TARGET_rockchip_rk3568=y
CONFIG_TARGET_MULTI_PROFILE=y
CONFIG_TARGET_DEVICE_rockchip_rk3568_DEVICE_friendlyarm-nanopi-r5s=y
CONFIG_IPV6=y

# Disable global options that pull in many packages
# CONFIG_ALL_KMODS is not set
# CONFIG_ALL_NONSHARED is not set
# CONFIG_DEVEL is not set
# CONFIG_BUILDBOT is not set
# CONFIG_ALL is not set
EOF

# 4. 核心包（必选）
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

# 5. 添加 Clashoo feed
FEED_CONF="friendlywrt/feeds.conf"
(cd friendlywrt && { [ ! -f feeds.conf ] && cp feeds.conf.default feeds.conf; })
grep -q "src-git clashoo" "$FEED_CONF" || echo "src-git clashoo https://github.com/kenzok8/openwrt-clashoo.git;main" >> "$FEED_CONF"

# 6. Clashoo 包
cat >> "$CONFIG_FILE" << 'EOF'
CONFIG_PACKAGE_clashoo=y
CONFIG_PACKAGE_luci-app-clashoo=y
CONFIG_PACKAGE_luci-i18n-clashoo-zh-cn=y
CONFIG_PACKAGE_kmod-inet-diag=y
EOF

# 7. 自定义包（包含 Python 依赖）
ENSURE_PKGS="
bc vsftpd sudo unzip file procd logrotate coreutils-stat lsof jq wireguard-tools python3-light libpython3
"
for pkg in $ENSURE_PKGS; do
    echo "CONFIG_PACKAGE_${pkg}=y" >> "$CONFIG_FILE"
done

# 8. 显式禁用常见不需要的包（减少固件体积）
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
    echo "# CONFIG_PACKAGE_${pkg} is not set" >> "$CONFIG_FILE"
done

# 9. 额外禁用所有其他 Python 包（保留我们需要的）
EXTRA_PYTHON_DISABLE="
micropython-lib micropython-lib-src micropython-lib-unix micropython-lib-unix-src
micropython-mbedtls micropython-nossl pipx python3-aio-mqtt-mod python3-aiosignal
python3-apipkg python3-apparmor python3-appdirs python3-argcomplete python3-asgiref
python3-async-generator python3-async-timeout
"
for pkg in $EXTRA_PYTHON_DISABLE; do
    echo "# CONFIG_PACKAGE_${pkg} is not set" >> "$CONFIG_FILE"
done

# 10. 更新 Clashoo feed 并安装所有包（确保依赖可用）
(cd friendlywrt && ./scripts/feeds update clashoo && ./scripts/feeds install -a)

# 11. 修改内核配置启用 INET_DIAG
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

# 12. UCI 预配置
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

# 13. 进入构建目录，运行 make defconfig
cd friendlywrt
echo "=== Running make defconfig ==="
make defconfig

# 14. 强制启用 Clashoo 包（如果 defconfig 未启用）
echo "=== Force-enabling Clashoo packages ==="
for pkg in clashoo luci-app-clashoo luci-i18n-clashoo-zh-cn kmod-inet-diag; do
    sed -i "s/^# CONFIG_PACKAGE_${pkg} is not set$/CONFIG_PACKAGE_${pkg}=y/" .config
    grep -q "^CONFIG_PACKAGE_${pkg}=y" .config || echo "CONFIG_PACKAGE_${pkg}=y" >> .config
done

# 15. 禁用所有不必要的 Python 包（避免 oldconfig 交互）
echo "=== Disabling extra Python packages ==="
for pkg in $(grep -E '^CONFIG_PACKAGE_(libpython|python|micropython)' .config | cut -d= -f1 | sed 's/^CONFIG_PACKAGE_//'); do
    if [ "$pkg" != "python3-light" ] && [ "$pkg" != "libpython3" ]; then
        sed -i "s/^CONFIG_PACKAGE_${pkg}=.*/# CONFIG_PACKAGE_${pkg} is not set/" .config
        grep -q "^# CONFIG_PACKAGE_${pkg} is not set" .config || echo "# CONFIG_PACKAGE_${pkg} is not set" >> .config
    fi
done

# 16. 运行 oldconfig，自动接受所有默认值（避免交互）
echo "=== Running make oldconfig (non-interactive) ==="
yes "" | make oldconfig

# 17. 验证 Clashoo 包是否成功启用
echo "=== Verifying Clashoo packages ==="
for pkg in clashoo luci-app-clashoo luci-i18n-clashoo-zh-cn kmod-inet-diag; do
    if grep -q "^CONFIG_PACKAGE_${pkg}=y" .config; then
        echo "[OK] CONFIG_PACKAGE_${pkg}=y"
    else
        echo "[FAIL] CONFIG_PACKAGE_${pkg} not enabled"
        exit 1
    fi
done

echo "=== Final package count ==="
echo "Enabled packages in .config: $(grep -c '^CONFIG_PACKAGE_.*=y' .config || echo 0)"

cd ..
echo "All configurations applied and verified."