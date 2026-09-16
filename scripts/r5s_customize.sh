#!/bin/bash
set -e

STAGE="$1"

CLASHOO_FEED="src-git clashoo https://github.com/kenzok8/openwrt-clashoo.git;main"
AMLOGIC_REPO="https://github.com/ophub/luci-app-amlogic.git"

pre_feeds() {
    [ ! -f feeds.conf ] && cp feeds.conf.default feeds.conf

    sed -i '/^#/d' feeds.conf
    sed -i -e 's|git.openwrt.org/feed|github.com/openwrt|g' \
           -e 's|git.openwrt.org/project|github.com/openwrt|g' feeds.conf

    grep -q "src-git clashoo" feeds.conf || echo "$CLASHOO_FEED" >> feeds.conf

    if [ -f tools/libtool/Makefile ]; then
        python3 - << 'PYEOF'
import re

path = 'tools/libtool/Makefile'
with open(path) as f:
    content = f.read()

if 'rm -rf .git; git init' in content:
    print('tools/libtool/Makefile: already patched')
else:
    pattern = r'(\(\s*cd \$\(HOST_BUILD_DIR\)\s*;)'
    replacement = (
        r'\1 '
        r'rm -rf .git; '
        r'git init -q . >/dev/null 2>&1 || true; '
        r'git config user.email ci@local >/dev/null 2>&1 || true; '
        r'git config user.name CI >/dev/null 2>&1 || true; '
    )
    new_content, n = re.subn(pattern, replacement, content, count=1)
    if n > 0:
        with open(path, 'w') as f:
            f.write(new_content)
        print('tools/libtool/Makefile: patched')
    else:
        print('tools/libtool/Makefile: pattern not found, skipping')
PYEOF
    fi
}

post_feeds() {
    sed -i 's/192.168.1.1/192.168.3.3/g' package/base-files/files/bin/config_generate

    KERNEL_VERSION=$(grep '^KERNEL_PATCHVER' target/linux/rockchip/Makefile | cut -d= -f2 | tr -d ' ')
    [ -z "$KERNEL_VERSION" ] && KERNEL_VERSION="6.12"
    KERNEL_CONFIG_FILE="target/linux/rockchip/config-${KERNEL_VERSION}"
    touch "$KERNEL_CONFIG_FILE"

    for opt in INET_DIAG INET_TCP_DIAG INET_UDP_DIAG INET_RAW_DIAG \
               BRIDGE BRIDGE_NETFILTER NF_IP_VS NETFILTER_XT_MATCH_PHYSDEV NF_NAT; do
        sed -i "/^# CONFIG_${opt} is not set/d" "$KERNEL_CONFIG_FILE"
        sed -i "/^CONFIG_${opt}=/d" "$KERNEL_CONFIG_FILE"
        echo "CONFIG_${opt}=y" >> "$KERNEL_CONFIG_FILE"
    done

    mkdir -p package/custom
    rm -rf package/custom/luci-app-amlogic
    git clone --depth 1 "$AMLOGIC_REPO" package/custom/luci-app-amlogic 2>&1 | tail -2
    rm -rf package/custom/luci-app-amlogic/.git

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

    mkdir -p files/etc/docker
    cat > files/etc/docker/daemon.json << 'EOF'
{
  "data-root": "/opt/docker",
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  }
}
EOF
}

config_stage() {
    for opt in CONFIG_ALL_KMODS CONFIG_ALL_NONSHARED CONFIG_DEVEL CONFIG_BUILDBOT; do
        sed -i "s/^${opt}=.*/# ${opt} is not set/" .config || true
        grep -q "^# ${opt} is not set" .config || echo "# ${opt} is not set" >> .config
    done

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

    for pkg in clashoo luci-app-clashoo luci-i18n-clashoo-zh-cn kmod-inet-diag \
               luci-app-amlogic luci-lib-nixio \
               luci-app-ttyd ttyd luci-i18n-ttyd-zh-cn \
               docker dockerd docker-compose containerd runc tini libnetwork \
               luci-app-dockerman luci-lib-docker luci-i18n-dockerman-zh-cn cgroupfs-mount \
               kmod-br-netfilter kmod-veth kmod-nf-ipvs kmod-ipt-physdev \
               kmod-ipt-tee kmod-ipt-nat6 kmod-ipt-nat-extra \
               kmod-nf-nathelper kmod-nf-nathelper-extra \
               kmod-fs-overlay kmod-fuse \
               iptables-nft iptables-zz-legacy \
               iptables-mod-conntrack-extra iptables-mod-ipopt iptables-mod-extra iptables-mod-filter \
               ip6tables-nft ip6tables-extra; do
        sed -i "/^# CONFIG_PACKAGE_${pkg} is not set/d" .config
        sed -i "/^CONFIG_PACKAGE_${pkg}=/d" .config
        echo "CONFIG_PACKAGE_${pkg}=y" >> .config
    done

    MISSING=0
    for pkg in clashoo luci-app-clashoo kmod-inet-diag luci-app-amlogic luci-app-ttyd ttyd docker dockerd luci-app-dockerman; do
        if grep -q "^CONFIG_PACKAGE_${pkg}=y" .config; then
            echo "[OK] $pkg"
        else
            echo "[FAIL] $pkg"
            MISSING=1
        fi
    done
    if [ $MISSING -eq 1 ]; then
        echo "ERROR: required packages not enabled"
        exit 1
    fi
}

case "$STAGE" in
    pre)    pre_feeds ;;
    post)   post_feeds ;;
    config) config_stage ;;
    *)      echo "Usage: $0 {pre|post|config}"; exit 1 ;;
esac