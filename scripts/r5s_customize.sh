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

    for opt in INET_DIAG INET_TCP_DIAG INET_UDP_DIAG INET_RAW_DIAG \
               BRIDGE BRIDGE_NETFILTER NF_IP_VS NETFILTER_XT_MATCH_PHYSDEV NF_NAT \
               CGROUP_DEVICE CGROUP_FREEZER CGROUP_SCHED CGROUP_BPF \
               CGROUP_PIDS CGROUP_RDMA CGROUP_HUGETLB CGROUP_NET_CLASSID \
               MEMCG BLK_CGROUP CFS_BANDWIDTH FAIR_GROUP_SCHED RT_GROUP_SCHED \
               CGROUP_PERF CGROUP_NET_PRIO \
               PWM PWM_SYSFS PWM_ROCKCHIP SENSORS_PWM_FAN \
               LEDS_TRIGGER_NETDEV LED_TRIGGER_PHY; do
        sed -i "/^# CONFIG_${opt} is not set/d" "$KERNEL_CONFIG_FILE"
        sed -i "/^CONFIG_${opt}=/d" "$KERNEL_CONFIG_FILE"
        echo "CONFIG_${opt}=y" >> "$KERNEL_CONFIG_FILE"
    done

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

    cat > files/etc/uci-defaults/90-opt-partition << 'EOF'
#!/bin/sh
[ -f /etc/.opt_partition_done ] && exit 0
touch /etc/.opt_partition_done

ROOT_DEV=$(findmnt -n -o SOURCE / 2>/dev/null | head -1)
[ -z "$ROOT_DEV" ] && exit 0
REAL_DEV=$(readlink -f "$ROOT_DEV" 2>/dev/null)
[ -b "$REAL_DEV" ] && ROOT_DEV="$REAL_DEV"

case "$ROOT_DEV" in
    /dev/mmcblk*p*)     DISK="/dev/$(basename "$ROOT_DEV" | sed 's/p[0-9]*$//')"; P="p" ;;
    /dev/sd[a-z][0-9]*) DISK="/dev/$(basename "$ROOT_DEV" | sed 's/[0-9]*$//')"; P="" ;;
    *) exit 0 ;;
esac

OPT_DEV="${DISK}${P}3"
[ ! -b "$OPT_DEV" ] && { logger -t opt-init "p3 not found, skip"; exit 0; }

FSTYPE=$(blkid -s TYPE -o value "$OPT_DEV" 2>/dev/null)
if [ "$FSTYPE" != "ext4" ]; then
    logger -t opt-init "mkfs.ext4 on $OPT_DEV"
    mkfs.ext4 -L opt -F "$OPT_DEV" >/dev/null 2>&1 || exit 0
fi

UUID=$(blkid -s UUID -o value "$OPT_DEV" 2>/dev/null)
[ -z "$UUID" ] && exit 0

uci -q delete fstab.opt
uci set fstab.opt=mount
uci set fstab.opt.target='/opt'
uci set fstab.opt.uuid="$UUID"
uci set fstab.opt.fstype='ext4'
uci set fstab.opt.options='rw,relatime'
uci set fstab.opt.enabled='1'
uci commit fstab

mkdir -p /opt
mountpoint -q /opt || mount -t ext4 "$OPT_DEV" /opt 2>/dev/null
mkdir -p /opt/docker
chmod 0700 /opt/docker

logger -t opt-init "/opt mounted on $OPT_DEV UUID=$UUID"
exit 0
EOF
    chmod +x files/etc/uci-defaults/90-opt-partition

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
            temperature = <40000>;
            hysteresis = <2000>;
            type = "active";
        };
        cpu_hot: cpu_hot {
            temperature = <45000>;
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
    echo "pwm-fan node injected"
}

# 在镜像 GPT 中加入 p3=/opt（2GB），然后 gzip -9n 压缩
add_opt_partition() {
    local OUT="bin/targets/rockchip/armv8"

    process_img() {
        local IMG="$1"

        if [ ! -f "$IMG" ] && [ -f "${IMG}.gz" ]; then
            gzip -d "${IMG}.gz"
        fi
        [ -f "$IMG" ] || return 0

        python3 - "$IMG" << 'PYEOF'
import struct, zlib, sys, os

img = sys.argv[1]
P3_SIZE = 2 * 1024 * 1024 * 1024
SECTOR  = 512
ALIGN   = 2048

with open(img, 'r+b') as f:
    f.seek(512)
    header = bytearray(f.read(92))
    if header[:8] != b'EFI PART':
        print("ERROR: not a GPT image"); sys.exit(1)

    f.seek(1024)
    entries = bytearray(f.read(128 * 128))

    p3_off = 2 * 128
    if entries[p3_off:p3_off+16] != b'\x00' * 16:
        print("p3 exists, skip"); sys.exit(0)

    p2_last = struct.unpack('<Q', entries[128+40:128+48])[0]

    p3_first = ((p2_last + 1 + ALIGN - 1) // ALIGN) * ALIGN
    p3_last  = p3_first + (P3_SIZE // SECTOR) - 1

    new_size = (p3_last + 1 + 33) * SECTOR
    if os.path.getsize(img) < new_size:
        f.truncate(new_size)

    new_last_lba = (new_size // SECTOR) - 1
    header[32:40] = struct.pack('<Q', new_last_lba)
    header[48:56] = struct.pack('<Q', new_last_lba - 33)

    entries[p3_off:p3_off+16] = bytes.fromhex('af3dc60f838472478e793d69d8477de4')
    entries[p3_off+16:p3_off+32] = bytes.fromhex('8f3c4a1e5b2d4f7e9a1c3e5f7a9b1d3f')
    entries[p3_off+32:p3_off+40] = struct.pack('<Q', p3_first)
    entries[p3_off+40:p3_off+48] = struct.pack('<Q', p3_last)
    name = "opt".encode('utf-16-le')
    entries[p3_off+56:p3_off+56+len(name)] = name

    header[88:92] = struct.pack('<I', zlib.crc32(entries) & 0xFFFFFFFF)

    header[16:20] = b'\x00\x00\x00\x00'
    header[16:20] = struct.pack('<I', zlib.crc32(header) & 0xFFFFFFFF)

    f.seek(512);  f.write(header)
    f.seek(1024); f.write(entries)

    backup_header = bytearray(header)
    backup_header[24:32] = struct.pack('<Q', new_last_lba)
    backup_header[32:40] = struct.pack('<Q', 1)
    backup_header[16:20] = b'\x00\x00\x00\x00'
    backup_header[16:20] = struct.pack('<I', zlib.crc32(backup_header) & 0xFFFFFFFF)

    f.seek((new_last_lba - 32) * SECTOR); f.write(entries)
    f.seek(new_last_lba * SECTOR);        f.write(backup_header)

    print(f"p3 added: LBA {p3_first}..{p3_last} ({P3_SIZE//1024//1024}MB), img={new_size//1024//1024}MB")
PYEOF

        gzip -9n -c "$IMG" > "${IMG}.gz"
        rm -f "$IMG"
    }

    local IMG_EXT4 IMG_SQ
    IMG_EXT4=$(find "$OUT" -maxdepth 1 -type f \
        \( -name "*nanopi-r5s-ext4-sysupgrade.img" -o -name "*nanopi-r5s-ext4-sysupgrade.img.gz" \) \
        2>/dev/null | head -1)
    [ -n "$IMG_EXT4" ] && process_img "${IMG_EXT4%.gz}"

    IMG_SQ=$(find "$OUT" -maxdepth 1 -type f \
        \( -name "*nanopi-r5s-squashfs-sysupgrade.img" -o -name "*nanopi-r5s-squashfs-sysupgrade.img.gz" \) \
        2>/dev/null | head -1)
    [ -n "$IMG_SQ" ] && process_img "${IMG_SQ%.gz}"

    ls -lh "$OUT"/*nanopi-r5s* 2>/dev/null || true
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
    grep -E "^CONFIG_TARGET_IMAGES_GZIP" .config || true

    local KV
    KV=$(grep '^KERNEL_PATCHVER' target/linux/rockchip/Makefile 2>/dev/null | cut -d= -f2 | tr -d ' ')
    [ -z "$KV" ] && KV="6.12"
    grep -E "^CONFIG_(PWM|PWM_SYSFS|PWM_ROCKCHIP|SENSORS_PWM_FAN)=" "target/linux/rockchip/config-${KV}" 2>/dev/null || true
    grep -E "^CONFIG_(LEDS_TRIGGER_NETDEV|LED_TRIGGER_PHY)=" "target/linux/rockchip/config-${KV}" 2>/dev/null || true

    [ -f files/sbin/mountpoint ] || { echo "missing files/sbin/mountpoint"; exit 1; }
}

case "$STAGE" in
    pre)            pre_feeds ;;
    post)           post_feeds ;;
    config)         config_stage ;;
    pre_build)      pre_build ;;
    add_opt_part)   add_opt_partition ;;
    cache_restore)  cache_restore ;;
    cache_save)     cache_save ;;
    *)              echo "Usage: $0 {pre|post|config|pre_build|add_opt_part|cache_restore|cache_save}"; exit 1 ;;
esac