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

# 2. 清理 01-nanopi 中的包行，保留其他配置
CONFIG_FILE="configs/rockchip/01-nanopi"
sed -i -e '/^CONFIG_PACKAGE_/d' -e '/^# CONFIG_PACKAGE_.* is not set$/d' "$CONFIG_FILE"

# 3. 写入目标平台和核心设置
cat >> "$CONFIG_FILE" << 'EOF'
# Target platform (NanoPi R5S)
CONFIG_TARGET_rockchip=y
CONFIG_TARGET_rockchip_rk3568=y
CONFIG_TARGET_MULTI_PROFILE=y
CONFIG_TARGET_DEVICE_rockchip_rk3568_DEVICE_friendlyarm-nanopi-r5s=y
CONFIG_IPV6=y
EOF

# 核心包（不含 Python）
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

# 4. 添加 Clashoo feed
FEED_CONF="friendlywrt/feeds.conf"
(cd friendlywrt && { [ ! -f feeds.conf ] && cp feeds.conf.default feeds.conf; })
grep -q "src-git clashoo" "$FEED_CONF" || echo "src-git clashoo https://github.com/kenzok8/openwrt-clashoo.git;main" >> "$FEED_CONF"

# 5. Clashoo 包
cat >> "$CONFIG_FILE" << 'EOF'
CONFIG_PACKAGE_clashoo=y
CONFIG_PACKAGE_luci-app-clashoo=y
CONFIG_PACKAGE_luci-i18n-clashoo-zh-cn=y
CONFIG_PACKAGE_kmod-inet-diag=y
EOF

# 6. 自定义包（包含 libpython3 和 python3-light 以满足依赖）
ENSURE_PKGS="
bc vsftpd sudo unzip file procd logrotate coreutils-stat lsof jq wireguard-tools python3-light libpython3
"
for pkg in $ENSURE_PKGS; do
    echo "CONFIG_PACKAGE_${pkg}=y" >> "$CONFIG_FILE"
done

# 7. 更新 Clashoo feed
(cd friendlywrt && ./scripts/feeds update clashoo && ./scripts/feeds install -a -p clashoo)

# 8. 修改内核配置启用 INET_DIAG
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

# 9. UCI 预配置
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

# 10. 进入构建目录
cd friendlywrt

# 禁用全局选项
for opt in CONFIG_ALL_KMODS CONFIG_ALL_NONSHARED CONFIG_DEVEL CONFIG_BUILDBOT CONFIG_ALL; do
    sed -i "s/^${opt}=.*/# ${opt} is not set/" .config || echo "# ${opt} is not set" >> .config
done

make defconfig

# 11. 使用 scripts/config 精确控制包选项（避免交互）
echo "=== Setting package options via scripts/config ==="

# 禁用所有 Python 包（除了我们需要的）
# 首先禁用所有 python3-* 和 micropython 包
for pkg in $(./scripts/config --list | grep -E '^CONFIG_PACKAGE_(python3-|micropython)' | sed 's/=.*//' | sed 's/^CONFIG_PACKAGE_//'); do
    if [ "$pkg" != "python3-light" ] && [ "$pkg" != "libpython3" ]; then
        ./scripts/config --disable "CONFIG_PACKAGE_${pkg}" 2>/dev/null || true
    fi
done

# 显式启用需要的 Python 包
./scripts/config --enable CONFIG_PACKAGE_libpython3
./scripts/config --enable CONFIG_PACKAGE_python3-light

# 禁用不需要的包
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
    ./scripts/config --disable "CONFIG_PACKAGE_${pkg}" 2>/dev/null || true
done

# 强制启用所有需要的包
ALL_ENABLE="$CORE_PKGS $ENSURE_PKGS clashoo luci-app-clashoo luci-i18n-clashoo-zh-cn kmod-inet-diag"
for pkg in $ALL_ENABLE; do
    ./scripts/config --enable "CONFIG_PACKAGE_${pkg}" 2>/dev/null || true
done

# 二次确保 Clashoo 包
for pkg in clashoo luci-app-clashoo luci-i18n-clashoo-zh-cn kmod-inet-diag; do
    ./scripts/config --enable "CONFIG_PACKAGE_${pkg}" 2>/dev/null || true
done

# 12. 运行 oldconfig，自动接受所有默认值
echo "=== Running make oldconfig (non-interactive) ==="
yes "" | make oldconfig

# 13. 验证
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