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
    cat feeds.conf
}

post_feeds() {
    sed -i 's/192.168.1.1/192.168.3.3/g' package/base-files/files/bin/config_generate

    KERNEL_VERSION=$(grep '^KERNEL_PATCHVER' target/linux/rockchip/Makefile | cut -d= -f2 | tr -d ' ')
    [ -z "$KERNEL_VERSION" ] && KERNEL_VERSION="6.12"
    KERNEL_CONFIG_FILE="target/linux/rockchip/config-${KERNEL_VERSION}"
    touch "$KERNEL_CONFIG_FILE"

    # PROC_PAGE_MONITOR: Redis 需要 /proc/<pid>/smaps
    for opt in INET_DIAG INET_TCP_DIAG INET_UDP_DIAG INET_RAW_DIAG \
               BRIDGE BRIDGE_NETFILTER NF_IP_VS NETFILTER_XT_MATCH_PHYSDEV NF_NAT \
               CGROUP_DEVICE CGROUP_FREEZER CGROUP_SCHED CGROUP_BPF \
               CGROUP_PIDS CGROUP_RDMA CGROUP_HUGETLB CGROUP_NET_CLASSID \
               MEMCG BLK_CGROUP CFS_BANDWIDTH FAIR_GROUP_SCHED RT_GROUP_SCHED \
               CGROUP_PERF CGROUP_NET_PRIO \
               PWM PWM_SYSFS PWM_ROCKCHIP SENSORS_PWM_FAN \
               LEDS_TRIGGER_NETDEV LED_TRIGGER_PHY \
               PROC_PAGE_MONITOR; do
        sed -i "/^# CONFIG_${opt} is not set/d" "$KERNEL_CONFIG_FILE"
        sed -i "/^CONFIG_${opt}=/d" "$KERNEL_CONFIG_FILE"
        echo "CONFIG_${opt}=y" >> "$KERNEL_CONFIG_FILE"
    done

    # ptgen 生成 3 分区：kernel + rootfs + opt
    python3 - << 'PYEOF'
import sys, os
path = "scripts/gen_image_generic.sh"
if not os.path.exists(path):
    print(f"ERROR: {path} not found"); sys.exit(1)

with open(path, "r") as f:
    content = f.read()

if "R5S_OPT_PATCHED" in content:
    print("already patched, skip")
    sys.exit(0)

if 'set $(ptgen' not in content:
    print("ERROR: 'set $(ptgen' not found"); sys.exit(1)
if '-t "${ROOTFSPARTTYPE}" -p "${ROOTFSSIZE}m"' not in content:
    print("ERROR: rootfs partition args not found"); sys.exit(1)

content = content.replace(
    'set $(ptgen',
    'truncate -s $((KERNELSIZE + ROOTFSSIZE + 288))M "$OUTPUT"\nset $(ptgen',
    1
)
content = content.replace(
    '-t "${ROOTFSPARTTYPE}" -p "${ROOTFSSIZE}m"',
    '-t "${ROOTFSPARTTYPE}" -p "${ROOTFSSIZE}m" -t 0x83 -p 256m',
    1
)
content = "# R5S_OPT_PATCHED - added opt partition (MBR) to ptgen\n" + content

with open(path, "w") as f:
    f.write(content)

print("patched gen_image_generic.sh:")
for i, line in enumerate(content.split("\n"), 1):
    if "R5S_OPT_PATCHED" in line or "truncate -s" in line or "ptgen -o" in line:
        print(f"  {i}: {line}")
PYEOF

    mkdir -p package/custom
    rm -rf package/custom/luci-app-amlogic
    git clone --depth 1 "$AMLOGIC_REPO" package/custom/luci-app-amlogic 2>&1 | tail -2
    rm -rf package/custom/luci-app-amlogic/.git

    mkdir -p files/etc/uci-defaults files/etc/docker files/sbin

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

    # 首次启动初始化
    cat > files/etc/uci-defaults/99-custom << 'EOF'
#!/bin/sh

# docker0 声明（25.12 上游缺）
if ! uci -q get network.docker.device >/dev/null 2>&1; then
    uci set network.docker='interface'
    uci set network.docker.device='docker0'
    uci set network.docker.proto='none'
    uci set network.docker.auto='0'
fi
if ! uci show network 2>/dev/null | grep -qE "\.name=['\"]?docker0['\"]?"; then
    uci add network device >/dev/null
    uci set network.@device[-1].type='bridge'
    uci set network.@device[-1].name='docker0'
fi

uci set network.lan.ipaddr='192.168.3.3/24'
uci set network.lan.gateway='192.168.3.1'
uci set network.lan.dns='192.168.3.1'
uci delete network.lan.netmask 2>/dev/null
uci set network.lan.delegate='0'
uci set network.wan.clientid=''
uci set network.wan.peerdns='1'
uci commit network

uci set dhcp.lan.ignore='1'
uci commit dhcp

# firewall：LAN zone
uci set firewall.@zone[0].name='lan'
uci set firewall.@zone[0].input='ACCEPT'
uci set firewall.@zone[0].output='ACCEPT'
uci set firewall.@zone[0].forward='ACCEPT'
uci set firewall.@zone[0].network='lan'

# docker zone：device 直绑（不用 network=，避免 netifd 接管 bridge）
uci set firewall.docker=zone
uci set firewall.docker.name='docker'
uci set firewall.docker.input='ACCEPT'
uci set firewall.docker.output='ACCEPT'
uci set firewall.docker.forward='ACCEPT'
uci set firewall.docker.device='docker0'
uci set firewall.docker.masq='1'
uci set firewall.docker.mtu_fix='1'

# 三条 forwarding：docker <-> wan/lan
uci set firewall.fwd_docker_wan=forwarding
uci set firewall.fwd_docker_wan.src='docker'
uci set firewall.fwd_docker_wan.dest='wan'

uci set firewall.fwd_docker_lan=forwarding
uci set firewall.fwd_docker_lan.src='docker'
uci set firewall.fwd_docker_lan.dest='lan'

uci set firewall.fwd_lan_docker=forwarding
uci set firewall.fwd_lan_docker.src='lan'
uci set firewall.fwd_lan_docker.dest='docker'

uci commit firewall

printf "tony\ntony\n" | passwd root
uci set luci.main.mediaurlbase='/luci-static/bootstrap'
uci delete luci.themes.Argon 2>/dev/null || true
uci commit luci

for f in /etc/apk/repositories.d/*.list; do
    [ -f "$f" ] && sed -i '/clashoo/d; /dockerfeed/d' "$f"
done

SSHD_CONFIG="/etc/ssh/sshd_config"
if [ -f "$SSHD_CONFIG" ] && [ -x /etc/init.d/sshd ]; then
    sed -i 's/^#*PermitRootLogin.*/PermitRootLogin yes/' "$SSHD_CONFIG"
    /etc/init.d/sshd enable
    /etc/init.d/sshd restart
fi

for entry in "wan_led:green:wan:eth0" "lan1_led:green:lan-1:eth1" "lan2_led:green:lan-2:eth2"; do
    name="${entry%%:*}"; rest="${entry#*:}"
    sysfs="${rest%%:*}"; dev="${rest#*:}"
    uci -q delete "system.${name}"
    uci set "system.${name}=led"
    uci set "system.${name}.name=${name}"
    uci set "system.${name}.sysfs=${sysfs}"
    uci set "system.${name}.trigger=netdev"
    uci set "system.${name}.dev=${dev}"
    uci set "system.${name}.mode=link"
done
uci commit system
/etc/init.d/led restart 2>/dev/null || true

# /opt: 扩展 p3 到磁盘末尾 + 格式化 + 挂载
LOG="logger -t opt-init"
ROOT_DEV=$(findmnt -n -o SOURCE / 2>/dev/null | head -1)
if [ -n "$ROOT_DEV" ]; then
    REAL_DEV=$(readlink -f "$ROOT_DEV" 2>/dev/null)
    [ -b "$REAL_DEV" ] && ROOT_DEV="$REAL_DEV"

    case "$ROOT_DEV" in
        /dev/mmcblk*p*)     DISK="/dev/$(basename "$ROOT_DEV" | sed 's/p[0-9]*$//')"; P="p" ;;
        /dev/sd[a-z][0-9]*) DISK="/dev/$(basename "$ROOT_DEV" | sed 's/[0-9]*$//')"; P="" ;;
        *) DISK="" ;;
    esac

    if [ -n "$DISK" ]; then
        OPT_DEV="${DISK}${P}3"
        if [ -b "$OPT_DEV" ]; then
            if [ ! -f /etc/.opt_resized ]; then
                DISK_SECTORS=$(cat /sys/class/block/$(basename "$DISK")/size 2>/dev/null)
                if [ -n "$DISK_SECTORS" ]; then
                    P3_START=$(cat /sys/class/block/$(basename "$OPT_DEV")/start 2>/dev/null)
                    P3_CUR=$(cat /sys/class/block/$(basename "$OPT_DEV")/size 2>/dev/null)
                    TARGET=$((DISK_SECTORS - P3_START - 33))
                    if [ -n "$P3_START" ] && [ "$P3_CUR" -lt "$TARGET" ]; then
                        $LOG "resizing p3: $P3_CUR -> $TARGET"
                        command -v parted >/dev/null 2>&1 && \
                            parted -s "$DISK" resizepart 3 100% >/dev/null 2>&1
                        partprobe "$DISK" 2>/dev/null || blockdev --rereadpt "$DISK" 2>/dev/null || true
                        sleep 1
                    fi
                fi
                touch /etc/.opt_resized
            fi

            FSTYPE=$(blkid -s TYPE -o value "$OPT_DEV" 2>/dev/null)
            if [ "$FSTYPE" != "ext4" ]; then
                $LOG "mkfs.ext4 on $OPT_DEV"
                mkfs.ext4 -L opt -F "$OPT_DEV" >/dev/null 2>&1
            else
                command -v resize2fs >/dev/null 2>&1 && resize2fs "$OPT_DEV" >/dev/null 2>&1 || true
            fi

            UUID=$(blkid -s UUID -o value "$OPT_DEV" 2>/dev/null)
            if [ -n "$UUID" ]; then
                if ! uci -q get fstab.opt >/dev/null 2>&1; then
                    uci set fstab.opt=mount
                    uci set fstab.opt.target='/opt'
                    uci set fstab.opt.uuid="$UUID"
                    uci set fstab.opt.fstype='ext4'
                    uci set fstab.opt.options='rw,relatime'
                    uci set fstab.opt.enabled='1'
                    uci commit fstab
                fi
                mkdir -p /opt
                mountpoint -q /opt || mount -t ext4 "$OPT_DEV" /opt 2>/dev/null
                mkdir -p /opt/docker
                chmod 0700 /opt/docker
                $LOG "/opt mounted on $OPT_DEV UUID=$UUID"
            fi
        fi
    fi
fi

exit 0
EOF
    chmod +x files/etc/uci-defaults/99-custom

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

pre_build() {
    make target/linux/prepare V=s > /dev/null 2>&1 || true

    local DTS=""
    DTS=$(find build_dir -type f -path "*/arch/arm64/boot/dts/rockchip/rk3568-nanopi-r5s.dts" 2>/dev/null | head -1)
    [ -z "$DTS" ] && DTS=$(find . -type f -path "*/arch/arm64/boot/dts/rockchip/rk3568-nanopi-r5s.dts" 2>/dev/null | head -1)

    [ -z "$DTS" ] && { echo "r5s dts not found, skip"; return 0; }

    if grep -q "pwm-fan" "$DTS"; then
        echo "dts already patched"
        return 0
    fi

    cp "$DTS" "${DTS}.orig"
    cat >> "$DTS" << 'DTS_EOF'

&pinctrl {
    pwm4_fan {
        pwm4_fan_pins: pwm4-fan-pins {
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
            temperature = <50000>;
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
    echo "pwm-fan node injected (45C->1, 50C->2)"
}

cache_restore() {
    if docker pull "$CACHE_IMAGE" 2>/dev/null; then
        cd /workdir
        docker create --name cache_container "$CACHE_IMAGE" /bin/true > /dev/null
        docker export cache_container > cache_exported.tar
        docker rm cache_container > /dev/null
        docker rmi "$CACHE_IMAGE" -f > /dev/null 2>&1 || true

        tar -xf cache_exported.tar --wildcards "op_cache_raw_*" 2>/dev/null || true

        if ls op_cache_raw_* 1> /dev/null 2>&1; then
            cat op_cache_raw_* | tar -I "zstd -T0" -xf - -C /workdir/openwrt/
            echo "cache restored"
        fi
        rm -f cache_exported.tar op_cache_raw_*
    else
        echo "no cache"
    fi

    df -hT
}

cache_save() {
    cd /workdir/openwrt

    for linux_dir in build_dir/target-*/linux-*/; do
        [ -d "$linux_dir" ] && (cd "$linux_dir" && ls -dt linux-* 2>/dev/null | tail -n +2 | xargs -I {} rm -rf "{}")
    done
    [ -d "build_dir" ] && (cd build_dir && ls -dt toolchain-* 2>/dev/null | tail -n +2 | xargs -I {} rm -rf "{}")
    if [ -d "staging_dir" ]; then
        (cd staging_dir && ls -dt target-* 2>/dev/null | tail -n +2 | xargs -I {} rm -rf "{}")
        (cd staging_dir && ls -dt toolchain-* 2>/dev/null | tail -n +2 | xargs -I {} rm -rf "{}")
    fi

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

    ENABLE_PKGS="
    bc vsftpd sudo unzip file procd logrotate coreutils-stat lsof jq
    wireguard-tools python3-light
    bash perl parted curl dosfstools e2fsprogs resize2fs lsblk pv losetup uuidgen fdisk wget-ssl
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
               ip6tables-nft ip6tables-extra \
               sgdisk gptfdisk; do
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

    local MISSING=0
    for pkg in clashoo luci-app-clashoo kmod-inet-diag luci-app-amlogic luci-app-ttyd ttyd \
               docker dockerd containerd runc luci-app-dockerman openssh-sftp-server parted; do
        grep -q "^CONFIG_PACKAGE_${pkg}=y" .config || { echo "missing: $pkg"; MISSING=1; }
    done
    [ $MISSING -eq 1 ] && exit 1

    grep -E "^CONFIG_PACKAGE_kmod-(r8169|r8125|r8168)" .config || true
    grep -E "^CONFIG_PACKAGE_(docker|dockerd|containerd|runc|luci-app-dockerman|luci-lib-docker)" .config || true
    grep -E "^CONFIG_PACKAGE_openssh-sftp-server" .config || true
    grep -E "^CONFIG_PACKAGE_resize2fs=y" .config || true
    grep -E "^CONFIG_PACKAGE_sgdisk=y" .config || true
    grep -E "^CONFIG_TARGET_IMAGES_GZIP" .config || true

    local KV
    KV=$(grep '^KERNEL_PATCHVER' target/linux/rockchip/Makefile 2>/dev/null | cut -d= -f2 | tr -d ' ')
    [ -z "$KV" ] && KV="6.12"
    grep -E "^CONFIG_(PWM|PWM_SYSFS|PWM_ROCKCHIP|SENSORS_PWM_FAN)=" "target/linux/rockchip/config-${KV}" 2>/dev/null || true
    grep -E "^CONFIG_(LEDS_TRIGGER_NETDEV|LED_TRIGGER_PHY)=" "target/linux/rockchip/config-${KV}" 2>/dev/null || true
    grep -E "^CONFIG_PROC_PAGE_MONITOR=" "target/linux/rockchip/config-${KV}" 2>/dev/null || true

    [ -f files/sbin/mountpoint ] || { echo "missing files/sbin/mountpoint"; exit 1; }
}

case "$STAGE" in
    pre)        pre_feeds ;;
    post)       post_feeds ;;
    config)     config_stage ;;
    pre_build)  pre_build ;;
    cache_restore)  cache_restore ;;
    cache_save)     cache_save ;;
    *)          echo "Usage: $0 {pre|post|config|pre_build|cache_restore|cache_save}"; exit 1 ;;
esac