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

# ---- 3. 添加额外软件包编译配置（包含用户指定的工具） ----
EXTRA_PKGS="
CONFIG_PACKAGE_bc=y
CONFIG_PACKAGE_vsftpd=y
CONFIG_PACKAGE_openssh-sftp-server=y
CONFIG_PACKAGE_wget-ssl=y
CONFIG_PACKAGE_busybox=y
CONFIG_PACKAGE_sudo=y
CONFIG_PACKAGE_unzip=y
CONFIG_PACKAGE_file=y
CONFIG_PACKAGE_procd=y
CONFIG_PACKAGE_logrotate=y
CONFIG_PACKAGE_coreutils-stat=y
CONFIG_PACKAGE_lsof=y
"

# 追加额外软件包（去重）
for pkg in bc vsftpd openssh-sftp-server wget-ssl busybox sudo unzip file procd logrotate coreutils-stat lsof; do
    if ! grep -q "CONFIG_PACKAGE_${pkg}=y" "$CONFIG_FILE"; then
        echo "CONFIG_PACKAGE_${pkg}=y" >> "$CONFIG_FILE"
        echo "Added CONFIG_PACKAGE_${pkg}=y to $CONFIG_FILE"
    fi
done

# ---- 4. 添加 Python3、pip 和 ca-certificates（清华源所需） ----
PYTHON_PKGS="python3 python3-pip ca-certificates"
for pkg in $PYTHON_PKGS; do
    if ! grep -q "CONFIG_PACKAGE_${pkg}=y" "$CONFIG_FILE"; then
        echo "CONFIG_PACKAGE_${pkg}=y" >> "$CONFIG_FILE"
        echo "Added CONFIG_PACKAGE_${pkg}=y to $CONFIG_FILE"
    fi
done

# ---- 5. 创建 pip 配置文件（清华源） ----
mkdir -p friendlywrt/files/etc
cat > friendlywrt/files/etc/pip.conf << 'PIP_CONF'
[global]
index-url = https://pypi.tuna.tsinghua.edu.cn/simple
trusted-host = pypi.tuna.tsinghua.edu.cn
PIP_CONF
echo "Created /etc/pip.conf with Tsinghua mirror"

# ---- 6. 更新 feeds 并安装 Clashoo 相关包 ----
(cd friendlywrt && ./scripts/feeds update clashoo)
(cd friendlywrt && ./scripts/feeds install -a -p clashoo)

# ---- 7. 植入旁路由预配置（uci-defaults 脚本） ----
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

# 尝试升级 pip 到最新（可选，若网络可达则执行，失败不影响）
if command -v pip3 >/dev/null 2>&1; then
    pip3 install --upgrade pip > /dev/null 2>&1 &
fi

exit 0
EOF
chmod +x friendlywrt/files/etc/uci-defaults/99-custom
echo "Added custom uci-defaults for preset configuration, password, and optional pip upgrade"
