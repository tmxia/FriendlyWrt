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

    # 内核选项：容器/网络/PWM/风扇/LED netdev
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
        echo "===== 02_network: nanopi-r5s 条目 ====="
        grep -n -A5 'nanopi-r5s' "$NET_FILE" || echo "  (未找到)"
        echo "======================================"
    fi

    mkdir -p package/custom
    rm -rf package/custom/luci-app-amlogic
    git clone --depth 1 "$AMLOGIC_REPO" package/custom/luci-app-amlogic 2>&1 | tail -2
    rm -rf package/custom/luci-app-amlogic/.git

    mkdir -p files/etc/uci-defaults files/etc/docker files/sbin

    # shell 版 mountpoint（无需 util-linux，直接从 /proc/mounts 判断）
    cat > files/sbin/mountpoint << 'MP_EOF'
#!/bin/sh
QUIET=0; DEV=0
while [ $# -gt 0 ]; do
    case "$1" in
        -q) QUIET=1; shift ;;
        -d) DEV=1; shift ;;
        --) shift; break ;;
        -*) shift ;;
        *) break ;;
    esac
done
[ -z "$1" ] && { [ $QUIET -eq 0 ] && echo "usage: mountpoint [-q] [-d] path" >&2; exit 1; }
RAW="$1"
[ ! -d "$RAW" ] && [ ! -f "$RAW" ] && { [ $QUIET -eq 0 ] && echo "$RAW is not a mountpoint" >&2; exit 1; }
TARGET=$(readlink -f "$RAW" 2>/dev/null || echo "$RAW")
FOUND=0; DEVNAME=""
if [ -r /proc/mounts ]; then
    while read -r d m _rest; do
        m_clean=$(printf '%b' "$(echo "$m" | sed 's/\\040/ /g; s/\\011/\t/g; s/\\012/\n/g; s/\\134/\\/g')")
        [ "$m_clean" = "$TARGET" ] && { FOUND=1; DEVNAME="$d"; break; }
    done < /proc/mounts
fi
if [ $FOUND -eq 1 ]; then
    [ $QUIET -eq 1 ] && exit 0
    [ $DEV -eq 1 ] && echo "$DEVNAME" || echo "$TARGET is a mountpoint"
    exit 0
fi
[ $QUIET -eq 0 ] && echo "$TARGET is not a mountpoint" >&2
exit 1
MP_EOF
    chmod +x files/sbin/mountpoint

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

    cat > files/etc/uci-defaults/90-led-setup << 'EOF'
#!/bin/sh
uci -q delete system.wan_led
uci set system.wan_led=led
uci set system.wan_led.name='wan'
uci set system.wan_led.sysfs='green:wan'
uci set system.wan_led.trigger='netdev'
uci set system.wan_led.dev='eth0'
uci set system.wan_led.mode='link'

uci -q delete system.lan1_led
uci set system.lan1_led=led
uci set system.lan1_led.name='lan1'
uci set system.lan1_led.sysfs='green:lan-1'
uci set system.lan1_led.trigger='netdev'
uci set system.lan1_led.dev='eth1'
uci set system.lan1_led.mode='link'

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

    # 首启自动把 root 分区（p2）扩到整盘：
    #   1) parted resizepart 扩分区表
    #   2) losetup + resize2fs -f 绕过内核的 online resize 限制
    #   3) 写 pending 标记，由 zz-reboot-if-needed 触发一次自动重启让 fs 视图生效
    cat > files/etc/uci-defaults/90-extend-root << 'EOF'
#!/bin/sh
[ -f /etc/.root_extend_done ] && exit 0

ROOT_DEV=$(findmnt -n -o SOURCE / 2>/dev/null | head -1)
[ -z "$ROOT_DEV" ] && ROOT_DEV=$(mount | awk '$3=="/"{print $1; exit}')
[ -z "$ROOT_DEV" ] && { touch /etc/.root_extend_done; exit 0; }

REAL_DEV=$(readlink -f "$ROOT_DEV" 2>/dev/null)
[ -b "$REAL_DEV" ] && ROOT_DEV="$REAL_DEV"

case "$ROOT_DEV" in
    /dev/mmcblk*p*)     DISK="/dev/$(basename "$ROOT_DEV" | sed 's/p[0-9]*$//')"; PART=$(echo "$ROOT_DEV" | grep -oE '[0-9]+$') ;;
    /dev/sd[a-z][0-9]*) DISK="/dev/$(basename "$ROOT_DEV" | sed 's/[0-9]*$//')"; PART=$(echo "$ROOT_DEV" | grep -oE '[0-9]+$') ;;
    *) touch /etc/.root_extend_done; exit 0 ;;
esac

[ ! -b "$DISK" ] && { touch /etc/.root_extend_done; exit 0; }

DISK_SECTORS=$(cat "/sys/block/$(basename "$DISK")/size" 2>/dev/null)
[ -z "$DISK_SECTORS" ] && { touch /etc/.root_extend_done; exit 0; }

PART_END=$(parted -s "$DISK" unit s print 2>/dev/null | awk -v p="$PART" '$1==p {print $3}' | tr -d s)
[ -z "$PART_END" ] && { touch /etc/.root_extend_done; exit 0; }

FREE=$((DISK_SECTORS - PART_END))
# 剩余 < 5GB 就不折腾
[ "$FREE" -lt 10485760 ] && { touch /etc/.root_extend_done; exit 0; }

logger -t extend-root "Growing $DISK partition $PART (free=$((FREE * 512 / 1024 / 1024))MB)"

# 1) 扩分区表
if ! parted -s "$DISK" unit s resizepart "$PART" 100% 2>/dev/null; then
    logger -t extend-root "parted resizepart failed, abort"
    exit 0
fi

# 2) losetup + resize2fs -f（绕过内核 online resize 限制）
LOOP=$(losetup -f 2>/dev/null)
if [ -n "$LOOP" ] && losetup "$LOOP" "$ROOT_DEV" 2>/dev/null; then
    if resize2fs -f "$LOOP" 2>/dev/null; then
        logger -t extend-root "resize2fs via $LOOP OK"
        losetup -d "$LOOP" 2>/dev/null
        # fs 已扩，但内核挂载视图还是旧大小 → 重启后刷新
        touch /etc/.root_extend_done
        touch /var/run/root_extend_pending
        exit 0
    else
        logger -t extend-root "resize2fs via $LOOP failed"
        losetup -d "$LOOP" 2>/dev/null
    fi
else
    logger -t extend-root "losetup attach failed"
fi

# 3) losetup 也失败：保留分区表扩展结果，下次开机靠 rc.local 尝试
grep -q '# extend-root-fs' /etc/rc.local 2>/dev/null || {
    sed -i '/^exit 0/d' /etc/rc.local 2>/dev/null
    cat >> /etc/rc.local << RC
# extend-root-fs
if [ ! -f /etc/.root_fs_extended ]; then
    ROOT_DEV=\$(findmnt -n -o SOURCE / 2>/dev/null | head -1)
    [ -z "\$ROOT_DEV" ] && ROOT_DEV=\$(mount | awk '\$3=="/"{print \$1; exit}')
    [ -n "\$ROOT_DEV" ] && resize2fs -f "\$ROOT_DEV" 2>/dev/null && \\
        touch /etc/.root_fs_extended && touch /etc/.root_extend_done && \\
        logger -t extend-root "Filesystem resized post-boot"
fi
exit 0
RC
    chmod +x /etc/rc.local
}
touch /var/run/root_extend_pending
exit 0
EOF
    chmod +x files/etc/uci-defaults/90-extend-root

    # 所有 uci-defaults 跑完后：若 root 扩容待生效则自动重启
    cat > files/etc/uci-defaults/zz-reboot-if-needed << 'EOF'
#!/bin/sh
if [ -f /var/run/root_extend_pending ]; then
    rm -f /var/run/root_extend_pending
    logger -t extend-root "Auto reboot to apply rootfs resize"
    sleep 1
    reboot
fi
exit 0
EOF
    chmod +x files/etc/uci-defaults/zz-reboot-if-needed

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

# 注入 R5S 风扇 dts（自建 pinctrl 避开上游 /omit-if-no-ref/）
pre_build() {
    echo "===== Pre-build: 注入 R5S 风扇 dts 节点 ====="

    make target/linux/prepare V=s > /dev/null 2>&1 || true

    local DTS=""
    DTS=$(find build_dir -type f -path "*/arch/arm64/boot/dts/rockchip/rk3568-nanopi-r5s.dts" 2>/dev/null | head -1)
    [ -z "$DTS" ] && DTS=$(find . -type f -path "*/arch/arm64/boot/dts/rockchip/rk3568-nanopi-r5s.dts" 2>/dev/null | head -1)
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

&pinctrl {
    pwm4_fan {
        pwm4_fan_pins: pwm4-fan-pins {
            /* PWM4_M1 = GPIO0_C3, mux 1 */
            rockchip,pins = <0 RK_PC3 1 &pcfg_pull_none>;
        };
    };
};

&pwm4 {
    status = "okay";
    pinctrl-names = "default";
    pinctrl-0 = <&pwm4_fan_pins>;
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

    echo "✅ 已注入 pwm-fan 节点（GPIO0_C3 = PWM4_M1，45℃→1档，55℃→2档）"
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
    bash perl parted curl dosfstools e2fsprogs resize2fs lsblk pv losetup uuidgen fdisk
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

    for pkg in mount-utils util-linux-mountpoint; do
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

    echo "===== 网卡驱动 ====="
    grep -E "^CONFIG_PACKAGE_kmod-(r8169|r8125|r8168)" .config || echo "  (无)"

    echo "===== Docker ====="
    grep -E "^CONFIG_PACKAGE_(docker|dockerd|containerd|runc|luci-app-dockerman|luci-lib-docker)" .config || echo "  (无)"

    echo "===== SFTP ====="
    grep -E "^CONFIG_PACKAGE_openssh-sftp-server" .config || echo "  (无)"

    echo "===== 风扇/PWM 内核 ====="
    grep -E "^CONFIG_(PWM|PWM_SYSFS|PWM_ROCKCHIP|SENSORS_PWM_FAN)=" "$KERNEL_CONFIG_FILE" 2>/dev/null || echo "  (无)"

    echo "===== mountpoint ====="
    [ -f files/sbin/mountpoint ] && echo "[OK] shell 版已打包" || echo "[FAIL] 未找到 files/sbin/mountpoint"

    echo "===== resize2fs ====="
    grep -E "^CONFIG_PACKAGE_resize2fs=y" .config || echo "  (无)"
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