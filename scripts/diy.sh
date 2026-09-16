#!/bin/bash
set -e

STAGE="$1"

# Clashoo feed
CLASHOO_FEED="src-git clashoo https://github.com/kenzok8/openwrt-clashoo.git;main"
# Amlogic feed（包含 luci-app-amlogic）
AMLOGIC_FEED="src-git kenzo https://github.com/kenzok8/openwrt-packages.git"

# ============================================================
# 阶段一：feeds 更新前
# ============================================================
pre_feeds() {
    echo "=====> DIY [pre]: 配置 feeds"
    [ ! -f feeds.conf ] && cp feeds.conf.default feeds.conf

    sed -i '/^#/d' feeds.conf
    sed -i -e 's|git.openwrt.org/feed|github.com/openwrt|g' \
           -e 's|git.openwrt.org/project|github.com/openwrt|g' feeds.conf

    grep -q "src-git clashoo" feeds.conf || echo "$CLASHOO_FEED" >> feeds.conf
    grep -q "src-git kenzo" feeds.conf || echo "$AMLOGIC_FEED" >> feeds.conf

    echo "feeds.conf 已更新："
    grep -E "clashoo|kenzo" feeds.conf
}

# ============================================================
# 阶段二：feeds 更新后
# ============================================================
post_feeds() {
    echo "=====> DIY [post]: 应用定制"

    # 修改默认 IP
    sed -i 's/192.168.1.1/192.168.3.3/g' package/base-files/files/bin/config_generate

    # 内核 INET_DIAG（Clashoo 依赖）
    KERNEL_VERSION=$(grep '^KERNEL_PATCHVER' target/linux/rockchip/Makefile | cut -d= -f2 | tr -d ' ')
    [ -z "$KERNEL_VERSION" ] && KERNEL_VERSION="6.12"
    KERNEL_CONFIG_FILE="target/linux/rockchip/config-${KERNEL_VERSION}"
    touch "$KERNEL_CONFIG_FILE"
    for opt in INET_DIAG INET_TCP_DIAG INET_UDP_DIAG INET_RAW_DIAG; do
        sed -i "/^# CONFIG_${opt} is not set/d" "$KERNEL_CONFIG_FILE"
        sed -i "/^CONFIG_${opt}=/d" "$KERNEL_CONFIG_FILE"
        echo "CONFIG_${opt}=y" >> "$KERNEL_CONFIG_FILE"
    done
    echo "内核 INET_DIAG 已启用: $KERNEL_CONFIG_FILE"

    # UCI 默认设置（旁路由 + 密码 + 主题）
    mkdir -p files/etc/uci-defaults
    cat > files/etc/uci-defaults/99-custom << 'EOF'
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
    chmod +x files/etc/uci-defaults/99-custom

    # SSH 配置（Dropbear 2222，OpenSSH 22）
    cat > files/etc/uci-defaults/99-custom-ssh << 'EOF'
#!/bin/sh
/etc/init.d/dropbear stop
/etc/init.d/sshd stop 2>/dev/null
uci set dropbear.@dropbear[0].Port='2222'
uci commit dropbear
SSHD_CONFIG="/etc/ssh/sshd_config"
if [ -f "$SSHD_CONFIG" ]; then
    sed -i 's/^#*PermitRootLogin.*/PermitRootLogin yes/' "$SSHD_CONFIG"
    sed -i 's/^#*Port.*/Port 22/' "$SSHD_CONFIG"
fi
/etc/init.d/dropbear start
/etc/init.d/sshd enable 2>/dev/null
/etc/init.d/sshd start 2>/dev/null
exit 0
EOF
    chmod +x files/etc/uci-defaults/99-custom-ssh

    echo "UCI 默认设置已写入"
}

# ============================================================
# 阶段三：.config 加载后，make defconfig 前
# ============================================================
config_stage() {
    echo "=====> DIY [config]: 调整 .config"

    # 禁用全局构建选项
    for opt in CONFIG_ALL_KMODS CONFIG_ALL_NONSHARED CONFIG_DEVEL CONFIG_BUILDBOT; do
        sed -i "s/^${opt}=.*/# ${opt} is not set/" .config || true
        grep -q "^# ${opt} is not set" .config || echo "# ${opt} is not set" >> .config
    done

    # 需要禁用的第三方插件
    DISABLE_PKGS="
    adblock luci-app-adblock
    aria2 luci-app-aria2
    sqm-scripts nft-qos luci-app-nft-qos luci-app-sqm
    ddns-scripts luci-app-ddns
    miniupnpd-nftables luci-app-upnp
    samba4-libs samba4-server luci-app-samba4
    minidlna luci-app-minidlna
    luci-proto-3g luci-proto-qmi qmi-utils uqmi umbim usb-modeswitch-official
    iwlwifi-firmware-ax200 iwlwifi-firmware-ax210 mt76x2-firmware mt792x-firmware
    luci-app-diskman collectd luci-app-statistics
    luci-app-watchcat luci-theme-openwrt-2020
    luci-app-cpufreq luci-i18n-cpufreq-zh-cn
    luci-app-hd-idle hd-idle luci-i18n-hd-idle-zh-cn
    luci-app-nlbwmon nlbwmon luci-i18n-nlbwmon-zh-cn
    luci-app-smartdns smartdns luci-i18n-smartdns-zh-cn
    luci-app-openclash luci-app-passwall luci-app-passwall2
    luci-app-ssr-plus luci-app-homeproxy luci-app-mosdns
    luci-app-adguardhome luci-app-ddns-go luci-app-netdata
    luci-app-vlmcsd luci-app-vnstat2 luci-app-wechatpush
    luci-app-keepalived luci-app-ramfree luci-app-rustdesk-server
    luci-app-udpxy luci-app-wol
    luci-theme-argon luci-theme-aurora luci-theme-kucat
    luci-theme-material luci-theme-material3 luci-theme-openwrt
    "
    for pkg in $DISABLE_PKGS; do
        sed -i "s/^CONFIG_PACKAGE_${pkg}=.*/# CONFIG_PACKAGE_${pkg} is not set/" .config
        grep -q "^# CONFIG_PACKAGE_${pkg} is not set" .config || \
          echo "# CONFIG_PACKAGE_${pkg} is not set" >> .config
    done

    # 确保必需系统包启用
    ENABLE_PKGS="
    bc vsftpd sudo unzip file procd logrotate coreutils-stat lsof jq
    wireguard-tools python3-light
    bash perl parted curl dosfstools e2fsprogs lsblk pv losetup uuidgen fdisk
    block-mount blkid
    "
    for pkg in $ENABLE_PKGS; do
        sed -i "/^# CONFIG_PACKAGE_${pkg} is not set/d" .config
        sed -i "s/^CONFIG_PACKAGE_${pkg}=.*/CONFIG_PACKAGE_${pkg}=y/" .config
        grep -q "^CONFIG_PACKAGE_${pkg}=y" .config || echo "CONFIG_PACKAGE_${pkg}=y" >> .config
    done

    # 确保 Clashoo 相关包启用
    for pkg in clashoo luci-app-clashoo luci-i18n-clashoo-zh-cn kmod-inet-diag; do
        sed -i "/^# CONFIG_PACKAGE_${pkg} is not set/d" .config
        sed -i "/^CONFIG_PACKAGE_${pkg}=/d" .config
        echo "CONFIG_PACKAGE_${pkg}=y" >> .config
    done

    # 确保 luci-app-amlogic 及依赖启用
    AMLOGIC_PKGS="
    luci-app-amlogic luci-lib-nixio block-mount blkid parted curl
    dosfstools e2fsprogs lsblk pv losetup uuidgen bash perl fdisk
    "
    for pkg in $AMLOGIC_PKGS; do
        sed -i "/^# CONFIG_PACKAGE_${pkg} is not set/d" .config
        sed -i "/^CONFIG_PACKAGE_${pkg}=/d" .config
        echo "CONFIG_PACKAGE_${pkg}=y" >> .config
    done

    # 确保终端工具启用
    for pkg in luci-app-ttyd ttyd luci-i18n-ttyd-zh-cn; do
        sed -i "/^# CONFIG_PACKAGE_${pkg} is not set/d" .config
        sed -i "/^CONFIG_PACKAGE_${pkg}=/d" .config
        echo "CONFIG_PACKAGE_${pkg}=y" >> .config
    done

    # 验证
    echo "=====> 验证关键包"
    MISSING=0
    for pkg in clashoo luci-app-clashoo kmod-inet-diag luci-app-amlogic luci-app-ttyd ttyd; do
        if grep -q "^CONFIG_PACKAGE_${pkg}=y" .config; then
            echo "[OK] $pkg"
        else
            echo "[FAIL] $pkg"
            MISSING=1
        fi
    done
    if [ $MISSING -eq 1 ]; then
        echo "ERROR: 关键包未启用，中止。"
        exit 1
    fi
}

case "$STAGE" in
    pre)    pre_feeds ;;
    post)   post_feeds ;;
    config) config_stage ;;
    *)      echo "Usage: $0 {pre|post|config}"; exit 1 ;;
esac