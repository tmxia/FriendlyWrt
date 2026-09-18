#!/bin/bash
set -e

STAGE="$1"

CLASHOO_FEED="src-git clashoo https://github.com/kenzok8/openwrt-clashoo.git;main"
AMLOGIC_REPO="https://github.com/ophub/luci-app-amlogic.git"

CACHE_IMAGE="ghcr.io/$(echo "${GITHUB_REPOSITORY:-local/unknown}" | tr '[:upper:]' '[:lower:]')/r5s-base-cache:openwrt-25.12"

pre_feeds() {
    [ ! -f feeds.conf ] && cp feeds.conf.default feeds.conf
    sed -i '/^#/d' feeds.conf
    sed -i -e 's|git.openwrt.org/feed|github.com/openwrt|g' \
           -e 's|git.openwrt.org/project|github.com/openwrt|g' feeds.conf
    grep -q "src-git clashoo" feeds.conf || echo "$CLASHOO_FEED" >> feeds.conf

    echo "===== feeds.conf 最终内容 ====="
    cat feeds.conf
    echo "================================"
}

post_feeds() {
    sed -i 's/192.168.1.1/192.168.3.3/g' package/base-files/files/bin/config_generate

    KERNEL_VERSION=$(grep '^KERNEL_PATCHVER' target/linux/rockchip/Makefile | cut -d= -f2 | tr -d ' ')
    [ -z "$KERNEL_VERSION" ] && KERNEL_VERSION="6.12"
    KERNEL_CONFIG_FILE="target/linux/rockchip/config-${KERNEL_VERSION}"
    touch "$KERNEL_CONFIG_FILE"

    # 内核关键选项：容器、网络、PWM、风扇、LED netdev trigger
    for opt in INET_DIAG INET_TCP_DIAG INET_UDP_DIAG INET_RAW_DIAG \
               BRIDGE BRIDGE_NETFILTER NF_IP_VS NETFILTER_XT_MATCH_PHYSDEV NF_NAT \
               CGROUP_DEVICE CGROUP_FREEZER CGROUP_SCHED CGROUP_BPF \
               CGROUP_PIDS CGROUP_RDMA CGROUP_HUGETLB CGROUP_NET_CLASSID \
               MEMCG BLK_CGROUP CFS_BANDWIDTH FAIR_GROUP_SCHED RT_GROUP_SCHED \
               CGROUP_PERF CGROUP_NET_PRIO \
               PWM PWM_SYSFS PWM_ROCKCHIP SENSORS_PWM_FAN \
               LEDS_TRIGGER_NETDEV; do
        sed -i "/^# CONFIG_${opt} is not set/d" "$KERNEL_CONFIG_FILE"
        sed -i "/^CONFIG_${opt}=/d" "$KERNEL_CONFIG_FILE"
        echo "CONFIG_${opt}=y" >> "$KERNEL_CONFIG_FILE"
    done

    NET_FILE="target/linux/rockchip/armv8/base-files/etc/board.d/02_network"
    if [ -f "$NET_FILE" ]; then
        echo "===== 02_network: nanopi-r5s 条目（官方原样，只读） ====="
        grep -n -A5 'nanopi-r5s' "$NET_FILE" || echo "  (未找到)"
        echo "======================================================"
    fi

    mkdir -p package/custom
    rm -rf package/custom/luci-app-amlogic
    git clone --depth 1 "$AMLOGIC_REPO" package/custom/luci-app-amlogic 2>&1 | tail -2
    rm -rf package/custom/luci-app-amlogic/.git

    mkdir -p files/etc/uci-defaults
    mkdir -p files/etc/docker

    # ============================================================
    # 99-custom：网络 / 密码 / 主题 / Docker 目录 / 清理失效 feed
    # ============================================================
    cat > files/etc/uci-defaults/99-custom << 'EOF'
#!/bin/sh

uci set network.lan.ipaddr='192.168.3.3/24'
uci set network.lan.gateway='192.168.3.1'
uci set network.lan.dns='192.168.3.1'
uci delete network.lan.netmask 2>/dev/null
uci set network.lan.delegate='0'
uci commit network

uci set dhcp.lan.ignore='1'
uci commit dhcp

uci set firewall.@zone[0].name='lan'
uci set firewall.@zone[0].input='ACCEPT'
uci set firewall.@zone[0].output='ACCEPT'
uci set firewall.@zone[0].forward='ACCEPT'
uci set firewall.@zone[0].network='lan'
uci commit firewall

uci set network.wan.clientid=''
uci set network.wan.peerdns='1'
uci commit network

printf "tony\ntony\n" | passwd root

uci set luci.main.mediaurlbase='/luci-static/bootstrap'
uci delete luci.themes.Argon 2>/dev/null || true
uci commit luci

mkdir -p /opt/docker
chmod 0700 /opt/docker

for f in /etc/apk/repositories.d/*.list; do
    [ -f "$f" ] && sed -i '/clashoo/d; /dockerfeed/d' "$f"
done

exit 0
EOF
    chmod +x files/etc/uci-defaults/99-custom

    # ============================================================
    # 99-custom-ssh：如果装了 openssh-server 才动它
    # ============================================================
    cat > files/etc/uci-defaults/99-custom-ssh << 'EOF'
#!/bin/sh
SSHD_CONFIG="/etc/ssh/sshd_config"
if [ -f "$SSHD_CONFIG" ] && [ -x /etc/init.d/sshd ]; then
    sed -i 's/^#*PermitRootLogin.*/PermitRootLogin yes/' "$SSHD_CONFIG"
    sed -i 's/^#*Port .*/Port 2222/' "$SSHD_CONFIG"
    sed -i '/^Port 22$/d' "$SSHD_CONFIG"
    /etc/init.d/sshd enable
    /etc/init.d/sshd restart
fi
exit 0
EOF
    chmod +x files/etc/uci-defaults/99-custom-ssh

    # ============================================================
    # 90-led-setup：官方 netdev trigger 配置网口 LED
    # ============================================================
    cat > files/etc/uci-defaults/90-led-setup << 'EOF'
#!/bin/sh
# WAN
uci -q delete system.wan_led
uci set system.wan_led=led
uci set system.wan_led.name='wan'
uci set system.wan_led.sysfs='green:wan'
uci set system.wan_led.trigger='netdev'
uci set system.wan_led.dev='eth0'
uci set system.wan_led.mode='link'

# LAN1
uci -q delete system.lan1_led
uci set system.lan1_led=led
uci set system.lan1_led.name='lan1'
uci set system.lan1_led.sysfs='green:lan-1'
uci set system.lan1_led.trigger='netdev'
uci set system.lan1_led.dev='eth1'
uci set system.lan1_led.mode='link'

# LAN2
uci -q delete system.lan2_led
uci set system.lan2_led=led
uci set system.lan2_led.name='lan2'
uci set system.lan2_led.sysfs='green:lan-2'
uci set system.lan2_led.trigger='netdev'
uci set system.lan2_led.dev='eth2'
uci set system.lan2_led.mode='link'

uci commit system
/etc/init.d/led restart
exit 0
EOF
    chmod +x files/etc/uci-defaults/90-led-setup

    # ============================================================
    # 85-grow-rootfs：首次启动把 root 分区扩到整卡
    # ============================================================
    cat > files/etc/uci-defaults/85-grow-rootfs << 'EOF'
#!/bin/sh
[ -f /etc/.rootfs_resized ] && exit 0

ROOT_DEV=$(findmnt -n -o SOURCE / 2>/dev/null | head -1)
[ -z "$ROOT_DEV" ] && ROOT_DEV=$(mount | awk '$3=="/"{print $1; exit}')
[ -z "$ROOT_DEV" ] && { touch /etc/.rootfs_resized; exit 0; }

case "$ROOT_DEV" in
    /dev/mmcblk*p*)     DISK="/dev/$(basename "$ROOT_DEV" | sed 's/p[0-9]*$//')" ;;
    /dev/sd[a-z][0-9]*) DISK="/dev/$(basename "$ROOT_DEV" | sed 's/[0-9]*$//')" ;;
    *)                  touch /etc/.rootfs_resized; exit 0 ;;
esac
PART=$(echo "$ROOT_DEV" | grep -oE '[0-9]+$')

[ ! -b "$DISK" ] && { touch /etc/.rootfs_resized; exit 0; }
DISK_SECTORS=$(cat "/sys/block/$(basename "$DISK")/size" 2>/dev/null)
[ -z "$DISK_SECTORS" ] && { touch /etc/.rootfs_resized; exit 0; }

PART_END=$(parted -s "$DISK" unit s print 2>/dev/null | awk -v p="$PART" '$1==p {print $3}' | tr -d 's')
[ -z "$PART_END" ] && { touch /etc/.rootfs_resized; exit 0; }

if [ "$PART_END" -lt "$((DISK_SECTORS - 204800))" ]; then
    logger -t grow-rootfs "Resizing $DISK partition $PART to full disk"
    parted -s "$DISK" resizepart "$PART" 100% 2>/dev/null || true
    blockdev --rereadpt "$DISK" 2>/dev/null || partprobe "$DISK" 2>/dev/null || true
    sleep 1
    resize2fs "$ROOT_DEV" 2>/dev/null || true
fi

touch /etc/.rootfs_resized
exit 0
EOF
    chmod +x files/etc/uci-defaults/85-grow-rootfs

    # ============================================================
    # Docker daemon.json
    # ============================================================
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

# ================================================================
# pre_build：内核源码解压后注入 R5S 风扇 dts 节点
# ================================================================
pre_build() {
    echo "===== Pre-build: 注入 R5S 风扇 dts 节点 ====="

    make target/linux/prepare V=s > /dev/null 2>&1 || true

    local DTS=""
    DTS=$(find build_dir -type f -path "*/arch/arm64/boot/dts/rockchip/rk3568-nanopi-r5s.dts" 2>/dev/null | head -1)
    if [ -z "$DTS" ]; then
        DTS=$(find . -type f -path "*/arch/arm64/boot/dts/rockchip/rk3568-nanopi-r5s.dts" 2>/dev/null | head -1)
    fi
    if [ -z "$DTS" ]; then
        echo "⚠️ 未找到 rk3568-nanopi-r5s.dts，跳过"
        return 0
    fi
    echo "找到 dts: $DTS"

    if grep -q "pwm-fan" "$DTS"; then
        echo "✅ dts 已存在 pwm-fan 节点，跳过"
        return 0
    fi

    cp "$DTS" "${DTS}.orig"

    cat >> "$DTS" << 'DTS_EOF'

&pwm4 {
    status = "okay";
    pinctrl-0 = <&pwm4m0_pins>;
    pinctrl-names = "default";
};

/ {
    fan: pwm-fan {
        compatible = "pwm-fan";
        cooling-levels = <0 80 160 255>;
        pwms = <&pwm4 0 40000 0>;
        #cooling-cells = <2>;
        status = "okay";
    };
};

&cpu_thermal {
    trips {
        cpu_warm: cpu_warm {
            temperature = <45000>;
            hysteresis = <2000>;
            type = "active";
        };
        cpu_hot: cpu_hot {
            temperature = <55000>;
            hysteresis = <2000>;
            type = "active";
        };
    };
    cooling-maps {
        map_warm {
            trip = <&cpu_warm>;
            cooling-device = <&fan 1 1>;
        };
        map_hot {
            trip = <&cpu_hot>;
            cooling-device = <&fan 2 3>;
        };
    };
};
DTS_EOF

    echo "✅ 已注入 pwm-fan 节点（45℃→1档，55℃→2档，更热→3档）"
}

cache_restore() {
    echo "Attempting to restore build cache from GHCR: $CACHE_IMAGE"
    if docker pull "$CACHE_IMAGE" 2>/dev/null; then
        echo "Cache found. Extracting..."
        cd /workdir
        docker create --name cache_container "$CACHE_IMAGE" /bin/true > /dev/null
        docker export cache_container > cache_exported.tar
        docker rm cache_container > /dev/null
        docker rmi "$CACHE_IMAGE" -f > /dev/null 2>&1 || true

        tar -xf cache_exported.tar --wildcards "op_cache_raw_*" 2>/dev/null || true

        if ls op_cache_raw_* 1> /dev/null 2>&1; then
            cat op_cache_raw_* | tar -I "zstd -T0" -xf - -C /workdir/openwrt/
            rm -f cache_exported.tar op_cache_raw_*
            echo "Cache restored."
        else
            rm -f cache_exported.tar
            echo "No valid cache chunks found."
        fi
    else
        echo "No cache found. Will do full build."
    fi

    df -hT
}

cache_save() {
    echo "Saving build cache to GHCR: $CACHE_IMAGE"
    cd /workdir/openwrt

    echo "Pruning obsolete versions..."
    for linux_dir in build_dir/target-*/linux-*/; do
        [ -d "$linux_dir" ] && (cd "$linux_dir" && ls -dt linux-* 2>/dev/null | tail -n +2 | xargs -I {} rm -rf "{}")
    done
    [ -d "build_dir" ] && (cd build_dir && ls -dt toolchain-* 2>/dev/null | tail -n +2 | xargs -I {} rm -rf "{}")
    if [ -d "staging_dir" ]; then
        (cd staging_dir && ls -dt target-* 2>/dev/null | tail -n +2 | xargs -I {} rm -rf "{}")
        (cd staging_dir && ls -dt toolchain-* 2>/dev/null | tail -n +2 | xargs -I {} rm -rf "{}")
    fi

    echo "Packing build_dir, staging_dir, dl..."
    find dl -type f | xargs -r touch -t 200001010000
    tar -I "zstd -T0 -10" -cf - build_dir staging_dir dl | split -a 3 -d -b 5000M - /workdir/op_cache_raw_

    cd /workdir
    echo "FROM scratch" > Dockerfile
    count=1
    for f in op_cache_raw_*; do
        layer_dir="layer$count"
        mkdir -p "$layer_dir"
        mv "$f" "$layer_dir/"
        echo "COPY $layer_dir /" >> Dockerfile
        count=$((count + 1))
    done

    docker build -t "$CACHE_IMAGE" .
    docker push "$CACHE_IMAGE"
    echo "Cache pushed."

    rm -rf layer* Dockerfile op_cache_raw_* cache_exported.tar
    docker rmi "$CACHE_IMAGE" -f > /dev/null 2>&1 || true
    docker builder prune -a -f > /dev/null 2>&1 || true
    df -hT
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
    e2fsprogs-extra
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
               luci-app-dockerman luci-lib-docker luci-i18n-dockerman-zh-cn \
               openssh-sftp-server \
               kmod-br-netfilter kmod-veth kmod-nf-ipvs kmod-ipt-physdev \
               kmod-ipt-tee kmod-ipt-nat6 kmod-ipt-nat-extra \
               kmod-nf-nathelper kmod-nf-nathelper-extra \
               kmod-fs-overlay kmod-fuse \
               kmod-r8169 \
               iptables-nft \
               iptables-mod-conntrack-extra iptables-mod-ipopt iptables-mod-extra iptables-mod-filter \
               ip6tables-nft ip6tables-extra; do
        sed -i "/^# CONFIG_PACKAGE_${pkg} is not set/d" .config
        sed -i "/^CONFIG_PACKAGE_${pkg}=/d" .config
        echo "CONFIG_PACKAGE_${pkg}=y" >> .config
    done

    for pkg in iptables-zz-legacy ip6tables-zz-legacy iptables-legacy; do
        sed -i "s/^CONFIG_PACKAGE_${pkg}=.*/# CONFIG_PACKAGE_${pkg} is not set/" .config
        grep -q "^# CONFIG_PACKAGE_${pkg} is not set" .config || \
          echo "# CONFIG_PACKAGE_${pkg} is not set" >> .config
    done

    MISSING=0
    for pkg in clashoo luci-app-clashoo kmod-inet-diag luci-app-amlogic luci-app-ttyd ttyd \
               docker dockerd containerd runc luci-app-dockerman openssh-sftp-server parted; do
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

    echo "===== 网卡驱动 config 检查 ====="
    grep -E "^CONFIG_PACKAGE_kmod-(r8169|r8125|r8168)" .config || echo "  (无)"
    echo "==============================="

    echo "===== Docker 相关 config 检查 ====="
    grep -E "^CONFIG_PACKAGE_(docker|dockerd|containerd|runc|luci-app-dockerman|luci-lib-docker)" .config || echo "  (无)"
    echo "================================="

    echo "===== SFTP 相关 config 检查 ====="
    grep -E "^CONFIG_PACKAGE_openssh-sftp-server" .config || echo "  (无)"
    echo "================================="
}

case "$STAGE" in
    pre)           pre_feeds ;;
    post)          post_feeds ;;
    config)        config_stage ;;
    pre_build)     pre_build ;;
    cache_restore) cache_restore ;;
    cache_save)    cache_save ;;
    *)             echo "Usage: $0 {pre|post|config|pre_build|cache_restore|cache_save}"; exit 1 ;;
esac