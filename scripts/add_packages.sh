#!/bin/bash

set -e

# ---- 1. 添加 Clashoo feed ----
FEED_CONF="friendlywrt/feeds.conf"
if ! grep -q "src-git clashoo" "$FEED_CONF"; then
    echo "src-git clashoo https://github.com/kenzok8/openwrt-clashoo.git;main" >> "$FEED_CONF"
    echo "Added Clashoo feed to feeds.conf"
fi

# ---- 2. 添加 Clashoo 编译配置 ----
CONFIG_FILE="configs/rockchip/01-nanopi"
if ! grep -q "CONFIG_PACKAGE_luci-app-clashoo" "$CONFIG_FILE"; then
    cat >> "$CONFIG_FILE" << EOF

# Clashoo packages
CONFIG_PACKAGE_clashoo=y
CONFIG_PACKAGE_luci-app-clashoo=y
CONFIG_PACKAGE_luci-i18n-clashoo-zh-cn=y
EOF
    echo "Added Clashoo config to $CONFIG_FILE"
fi

# ---- 3. 更新 feeds 并安装 Clashoo 相关包 ----
(cd friendlywrt && ./scripts/feeds update clashoo)
(cd friendlywrt && ./scripts/feeds install -a -p clashoo)

# ---- 4. 植入旁路由预配置（uci-defaults 脚本） ----
mkdir -p friendlywrt/files/etc/uci-defaults
cat > friendlywrt/files/etc/uci-defaults/99-custom << 'EOF'
#!/bin/sh
# 旁路由固定 IP 配置
uci set network.lan.ipaddr='192.168.3.3'
uci set network.lan.gateway='192.168.3.1'
uci set network.lan.dns='192.168.3.1'
uci commit network

# 禁用 LAN 口 DHCP
uci set dhcp.lan.ignore='1'
uci commit dhcp

# 更改 root 密码为 tony（自动输入两次）
echo -e "tony\ntony" | passwd root > /dev/null 2>&1

exit 0
EOF
chmod +x friendlywrt/files/etc/uci-defaults/99-custom
echo "Added custom uci-defaults for preset configuration and password change"