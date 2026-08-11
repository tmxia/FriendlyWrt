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
EXTRA_PKGS="bc vsftpd openssh-sftp-server wget-ssl busybox sudo unzip file procd logrotate coreutils-stat lsof"

for pkg in $EXTRA_PKGS; do
    if ! grep -q "CONFIG_PACKAGE_${pkg}=y" "$CONFIG_FILE"; then
        echo "CONFIG_PACKAGE_${pkg}=y" >> "$CONFIG_FILE"
        echo "Added CONFIG_PACKAGE_${pkg}=y to $CONFIG_FILE"
    fi
done

# 添加依赖包
if ! grep -q "CONFIG_PACKAGE_cpufrequtils=y" "$CONFIG_FILE"; then
    echo "CONFIG_PACKAGE_cpufrequtils=y" >> "$CONFIG_FILE"
    echo "Added CONFIG_PACKAGE_cpufrequtils=y to $CONFIG_FILE"
fi
if ! grep -q "CONFIG_PACKAGE_netdata=y" "$CONFIG_FILE"; then
    echo "CONFIG_PACKAGE_netdata=y" >> "$CONFIG_FILE"
    echo "Added CONFIG_PACKAGE_netdata=y to $CONFIG_FILE"
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

# ---- 5.安装Clashoo代理 ----
(cd friendlywrt && ./scripts/feeds update clashoo)
(cd friendlywrt && ./scripts/feeds install -a -p clashoo)

# ---- 6.移除kmod-inet-diag依赖 ----
if [ -d friendlywrt/feeds/clashoo ]; then
    find friendlywrt/feeds/clashoo -name "Makefile" -exec sed -i 's/+kmod-inet-diag//g' {} \;
    echo "Removed kmod-inet-diag dependency from Clashoo Makefile(s)"
else
    echo "Warning: Clashoo feed directory not found, skip dependency fix"
fi

# ---- 7.植入旁路由预配置及主题切换 ----
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