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
# 强制编译内核模块（内核已支持，生成包避免依赖缺失）
CONFIG_PACKAGE_kmod-inet-diag=y
EOF
    echo "Added Clashoo config to $CONFIG_FILE"
fi

# ---- 3. 添加额外软件包（去重） ----
for pkg in bc vsftpd openssh-sftp-server wget-ssl busybox sudo unzip file procd logrotate coreutils-stat lsof; do
    if ! grep -q "CONFIG_PACKAGE_${pkg}=y" "$CONFIG_FILE"; then
        echo "CONFIG_PACKAGE_${pkg}=y" >> "$CONFIG_FILE"
        echo "Added CONFIG_PACKAGE_${pkg}=y to $CONFIG_FILE"
    fi
done

# ---- 4. 添加 Python3 相关 ----
PYTHON_PKGS="python3 python3-pip ca-certificates"
for pkg in $PYTHON_PKGS; do
    if ! grep -q "CONFIG_PACKAGE_${pkg}=y" "$CONFIG_FILE"; then
        echo "CONFIG_PACKAGE_${pkg}=y" >> "$CONFIG_FILE"
        echo "Added CONFIG_PACKAGE_${pkg}=y to $CONFIG_FILE"
    fi
done

# ---- 5. 设置默认主题为 Bootstrap ----
# 确保 Bootstrap 主题被编译（默认已有，但显式指定）
if ! grep -q "CONFIG_PACKAGE_luci-theme-bootstrap=y" "$CONFIG_FILE"; then
    echo "CONFIG_PACKAGE_luci-theme-bootstrap=y" >> "$CONFIG_FILE"
    echo "Added CONFIG_PACKAGE_luci-theme-bootstrap=y to $CONFIG_FILE"
fi
# 如果有 Argon 主题，取消其默认选中（但保留编译可选）
# 这里不强制移除，仅确保 bootstrap 被设置为默认（后续通过 uci-defaults 强制）

# ---- 6. 创建 pip 配置文件 ----
mkdir -p friendlywrt/files/etc
cat > friendlywrt/files/etc/pip.conf << 'PIP_CONF'
[global]
index-url = https://pypi.tuna.tsinghua.edu.cn/simple
trusted-host = pypi.tuna.tsinghua.edu.cn
PIP_CONF
echo "Created /etc/pip.conf with Tsinghua mirror"

# ---- 7. 更新 feeds 并安装 Clashoo 相关包 ----
(cd friendlywrt && ./scripts/feeds update clashoo)
(cd friendlywrt && ./scripts/feeds install -a -p clashoo)

# ---- 8. 修改 Clashoo Makefile，移除 kmod-inet-diag 依赖 ----
if [ -d friendlywrt/feeds/clashoo ]; then
    find friendlywrt/feeds/clashoo -name "Makefile" -exec sed -i 's/+kmod-inet-diag//g' {} \;
    echo "Removed kmod-inet-diag dependency from Clashoo Makefile(s)"
else
    echo "Warning: Clashoo feed directory not found, skip dependency fix"
fi

# ---- 9. 植入旁路由预配置 + 主题切换 ----
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

# 更改 root 密码为 tony
echo -e "tony\ntony" | passwd root > /dev/null 2>&1

# ==== 强制设置 LuCI 主题为 Bootstrap ====
uci set luci.main.mediaurlbase='/luci-static/bootstrap'
uci commit luci

# 尝试升级 pip 到最新（可选）
if command -v pip3 >/dev/null 2>&1; then
    pip3 install --upgrade pip > /dev/null 2>&1 &
fi

exit 0
EOF
chmod +x friendlywrt/files/etc/uci-defaults/99-custom
echo "Added custom uci-defaults for preset configuration, password, theme, and optional pip upgrade"