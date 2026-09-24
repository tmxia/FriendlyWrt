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

    PROFILE_FILE="package/base-files/files/etc/profile"
    if [ -f "$PROFILE_FILE" ] && ! grep -q 'PATH="\$PATH:\."' "$PROFILE_FILE"; then
        sed -i '/^export PATH=/a export PATH="$PATH:."' "$PROFILE_FILE"
        echo "profile: PATH appended with ."
    fi

    BUSYBOX_DEFAULTS="package/utils/busybox/Config-defaults.in"
    if [ -f "$BUSYBOX_DEFAULTS" ] && grep -q '^config BUSYBOX_DEFAULT_FEATURE_SH_EXTRA_QUIET$' "$BUSYBOX_DEFAULTS"; then
        python3 - << 'PYEOF'
import re
p = "package/utils/busybox/Config-defaults.in"
with open(p) as f:
    c = f.read()
pat = re.compile(
    r'(config\s+BUSYBOX_DEFAULT_FEATURE_SH_EXTRA_QUIET\s*\n'
    r'\s+bool\s*\n'
    r'\s+default\s+)n(\s*\n)'
)
c2, n = pat.subn(r'\1y\2', c)
if n == 0:
    print("busybox banner: already patched or pattern miss")
else:
    with open(p, "w") as f:
        f.write(c2)
    print(f"busybox banner: patched {n}")
PYEOF
    fi

    KERNEL_VERSION=$(grep '^KERNEL_PATCHVER' target/linux/rockchip/Makefile | cut -d= -f2 | tr -d ' ')
    [ -z "$KERNEL_VERSION" ] && KERNEL_VERSION="6.12"
    KERNEL_CONFIG_FILE="target/linux/rockchip/config-${KERNEL_VERSION}"
    touch "$KERNEL_CONFIG_FILE"

    for opt in INET_DIAG INET_TCP_DIAG INET_UDP_DIAG INET_RAW_DIAG \
               NF_IP_VS NETFILTER_XT_MATCH_PHYSDEV NF_NAT \
               CGROUP_SCHED CGROUP_BPF CGROUP_PIDS CGROUP_RDMA CGROUP_NET_CLASSID \
               BLK_CGROUP CFS_BANDWIDTH FAIR_GROUP_SCHED RT_GROUP_SCHED \
               PWM PWM_SYSFS PWM_ROCKCHIP SENSORS_PWM_FAN \
               LEDS_TRIGGER_NETDEV LED_TRIGGER_PHY \
               PROC_PAGE_MONITOR; do
        sed -i "/^# CONFIG_${opt} is not set/d" "$KERNEL_CONFIG_FILE"
        sed -i "/^CONFIG_${opt}=/d" "$KERNEL_CONFIG_FILE"
        echo "CONFIG_${opt}=y" >> "$KERNEL_CONFIG_FILE"
    done

    python3 - << 'PYEOF'
import sys, os
path = "scripts/gen_image_generic.sh"
if not os.path.exists(path):
    print(f"ERROR: {path} not found"); sys.exit(1)

with open(path, "r") as f:
    content = f.read()

if "R5S_OPT_PATCHED" in content:
    print("already patched, skip"); sys.exit(0)

if 'set $(ptgen' not in content or '-t "${ROOTFSPARTTYPE}" -p "${ROOTFSSIZE}m"' not in content:
    print("ERROR: ptgen args not found"); sys.exit(1)

content = content.replace(
    '-t "${ROOTFSPARTTYPE}" -p "${ROOTFSSIZE}m"',
    '-t "${ROOTFSPARTTYPE}" -p "${ROOTFSSIZE}m" -t 0x83 -p 256m', 1)
content = "# R5S_OPT_PATCHED\n" + content
with open(path, "w") as f:
    f.write(content)
print("patched gen_image_generic.sh")
PYEOF

    mkdir -p package/custom
    rm -rf package/custom/luci-app-amlogic
    git clone --depth 1 "$AMLOGIC_REPO" package/custom/luci-app-amlogic 2>&1 | tail -2
    rm -rf package/custom/luci-app-amlogic/.git

    mkdir -p files/sbin files/usr/bin files/etc/init.d files/etc/rc.d \
             files/etc/uci-defaults files/etc/docker files/etc/sysctl.d \
             files/etc/hotplug.d/net

    mkdir -p package/base-files/files/etc/profile.d

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

    cat > files/etc/init.d/rc.local << 'INITEOF'
#!/bin/sh /etc/rc.common
START=95

boot() {
    [ -f /etc/rc.local ] && sh /etc/rc.local
}
INITEOF
    chmod +x files/etc/init.d/rc.local
    ln -sf ../init.d/rc.local files/etc/rc.d/S95rc.local

    cat > files/etc/rc.local << 'RCEOF'
#!/bin/sh
LOG=/tmp/opt-init.log
exec >>"$LOG" 2>&1
echo "=== $(date +%FT%T) opt-init ==="

ROOT_DEV=$(findmnt -n -o SOURCE /rom 2>/dev/null | head -1)
[ ! -b "$ROOT_DEV" ] && {
    PARTUUID=$(sed -n 's/.*root=PARTUUID=\([^ ]*\).*/\1/p' /proc/cmdline)
    [ -n "$PARTUUID" ] && ROOT_DEV=$(blkid -t "PARTUUID=$PARTUUID" -o device 2>/dev/null | head -1)
}
[ ! -b "$ROOT_DEV" ] && ROOT_DEV=$(sed -n 's/.*root=\(\/dev\/[^ ]*\).*/\1/p' /proc/cmdline)
echo "root=$ROOT_DEV"
REAL=$(readlink -f "$ROOT_DEV" 2>/dev/null)
[ -b "$REAL" ] && ROOT_DEV="$REAL"

case "$ROOT_DEV" in
    /dev/mmcblk*p*)     DISK="/dev/$(basename "$ROOT_DEV" | sed 's/p[0-9]*$//')"; P="p" ;;
    /dev/sd[a-z][0-9]*) DISK="/dev/$(basename "$ROOT_DEV" | sed 's/[0-9]*$//')"; P="" ;;
    *) echo "no disk"; exit 0 ;;
esac
OPT_DEV="${DISK}${P}3"
[ -b "$OPT_DEV" ] || { echo "no p3"; exit 0; }

mountpoint -q /opt && { echo "already mounted"; exit 0; }

[ -x /etc/init.d/dockerd ] && /etc/init.d/dockerd stop 2>/dev/null
sleep 1
umount /opt/docker 2>/dev/null || true
umount /opt 2>/dev/null || true

DS=$(cat /sys/class/block/$(basename "$DISK")/size 2>/dev/null)
PS=$(cat /sys/class/block/$(basename "$OPT_DEV")/start 2>/dev/null)
PC=$(cat /sys/class/block/$(basename "$OPT_DEV")/size 2>/dev/null)
if [ -n "$DS" ] && [ -n "$PS" ] && [ -n "$PC" ] && [ "$PC" -lt $((DS - PS - 33)) ]; then
    echo "resize p3: $PC -> $((DS - PS - 33))"
    parted -s "$DISK" resizepart 3 100% 2>/dev/null
    partprobe "$DISK" 2>/dev/null || blockdev --rereadpt "$DISK" 2>/dev/null || true
    sleep 2
fi

FSTYPE=$(blkid -s TYPE -o value "$OPT_DEV" 2>/dev/null)
if [ "$FSTYPE" != "ext4" ]; then
    mkfs.ext4 -L opt -F "$OPT_DEV"
else
    e2fsck -fy "$OPT_DEV" >/dev/null 2>&1 || true
    resize2fs "$OPT_DEV" 2>/dev/null || mkfs.ext4 -L opt -F "$OPT_DEV"
fi

UUID=$(blkid -s UUID -o value "$OPT_DEV" 2>/dev/null)
[ -n "$UUID" ] && {
    [ "$(uci -q get fstab.@mount[-1].uuid)" = "$UUID" ] || {
        while uci -q delete fstab.@mount[-1]; do :; done
        uci add fstab mount >/dev/null
        uci set fstab.@mount[-1].target='/opt'
        uci set fstab.@mount[-1].uuid="$UUID"
        uci set fstab.@mount[-1].fstype='ext4'
        uci set fstab.@mount[-1].options='rw,relatime'
        uci set fstab.@mount[-1].enabled='1'
        uci commit fstab
    }
    mkdir -p /opt/docker
    chmod 0700 /opt/docker
    mount -t ext4 "$OPT_DEV" /opt
    echo "mounted: $(df -h /opt 2>/dev/null | tail -1)"
}
echo "=== done ==="
exit 0
RCEOF
    chmod +x files/etc/rc.local

    cat > files/etc/hotplug.d/net/99-led-netdev << 'HOTPLUG_EOF'
#!/bin/sh
[ "$ACTION" = "add" ] || exit 0
(
    i=0
    while [ $i -lt 30 ]; do
        if [ -e /sys/class/net/eth0 ] && [ -e /sys/class/net/eth1 ] && [ -e /sys/class/net/eth2 ]; then
            /etc/init.d/led restart >/dev/null 2>&1
            exit 0
        fi
        sleep 1
        i=$((i+1))
    done
) &
HOTPLUG_EOF
    chmod +x files/etc/hotplug.d/net/99-led-netdev

    cat > files/etc/sysctl.d/99-r5s.conf << 'EOF'
net.core.rmem_max = 67108864
net.core.wmem_max = 67108864
net.core.optmem_max = 65535
net.ipv4.tcp_fin_timeout = 30
net.ipv4.tcp_keepalive_time = 1200
net.ipv4.ip_local_port_range = 10000 65535
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_rmem = 8192 262144 67108864
net.ipv4.tcp_wmem = 8192 262144 67108864
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_no_metrics_save = 1
net.ipv4.tcp_notsent_lowat = 16384
net.netfilter.nf_conntrack_acct=1
net.netfilter.nf_conntrack_checksum=0
net.netfilter.nf_conntrack_max=65535
net.netfilter.nf_conntrack_tcp_timeout_established=7440
net.netfilter.nf_conntrack_udp_timeout=60
net.netfilter.nf_conntrack_udp_timeout_stream=180
net.netfilter.nf_conntrack_helper=1
net.core.default_qdisc = fq_codel
EOF

    cat > files/etc/uci-defaults/99-custom << 'EOF'
#!/bin/sh

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

uci set firewall.@zone[0].name='lan'
uci set firewall.@zone[0].input='ACCEPT'
uci set firewall.@zone[0].output='ACCEPT'
uci set firewall.@zone[0].forward='ACCEPT'
uci set firewall.@zone[0].network='lan'

uci set firewall.docker=zone
uci set firewall.docker.name='docker'
uci set firewall.docker.input='ACCEPT'
uci set firewall.docker.output='ACCEPT'
uci set firewall.docker.forward='ACCEPT'
uci set firewall.docker.device='docker0'
uci set firewall.docker.masq='1'
uci set firewall.docker.mtu_fix='1'

uci set firewall.fwd_docker_wan=forwarding
uci set firewall.fwd_docker_wan.src='docker'
uci set firewall.fwd_docker_wan.dest='wan'

uci set firewall.fwd_docker_lan=forwarding
uci set firewall.fwd_docker_lan.src='docker'
uci set firewall.fwd_docker_lan.dest='lan'

uci set firewall.fwd_lan_docker=forwarding
uci set firewall.fwd_lan_docker.src='lan'
uci set firewall.fwd_lan_docker.dest='docker'

uci set firewall.dockernet=zone
uci set firewall.dockernet.name='dockernet'
uci set firewall.dockernet.input='ACCEPT'
uci set firewall.dockernet.output='ACCEPT'
uci set firewall.dockernet.forward='ACCEPT'
uci set firewall.dockernet.device='br-*'
uci set firewall.dockernet.masq='1'
uci set firewall.dockernet.mtu_fix='1'

uci set firewall.fwd_dockernet_wan=forwarding
uci set firewall.fwd_dockernet_wan.src='dockernet'
uci set firewall.fwd_dockernet_wan.dest='wan'

uci set firewall.fwd_dockernet_lan=forwarding
uci set firewall.fwd_dockernet_lan.src='dockernet'
uci set firewall.fwd_dockernet_lan.dest='lan'

uci set firewall.fwd_lan_dockernet=forwarding
uci set firewall.fwd_lan_dockernet.src='lan'
uci set firewall.fwd_lan_dockernet.dest='dockernet'

uci commit firewall

uci set dockerd.globals.data_root='/opt/docker'
uci -q delete dockerd.globals.registry_mirrors
uci add_list dockerd.globals.registry_mirrors='https://docker.1ms.run'
uci -q delete dockerd.globals.dns
uci add_list dockerd.globals.dns='223.5.5.5'
uci add_list dockerd.globals.dns='119.29.29.29'
uci set dockerd.globals.alt_config_file='/etc/docker/daemon.json'
uci commit dockerd

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

uci -q delete system.wan_led 2>/dev/null
uci -q delete system.lan1_led 2>/dev/null
uci -q delete system.lan2_led 2>/dev/null
uci -q delete system.led_wan 2>/dev/null
uci -q delete system.led_lan1 2>/dev/null
uci -q delete system.led_lan2 2>/dev/null

add_led() {
    local name="$1" sysfs="$2" dev="$3"
    uci set "system.led_${name}=led"
    uci set "system.led_${name}.name=$(echo $name | tr a-z A-Z)"
    uci set "system.led_${name}.sysfs=${sysfs}"
    uci set "system.led_${name}.trigger=netdev"
    uci set "system.led_${name}.dev=${dev}"
    uci set "system.led_${name}.mode=link"
}

add_led wan  "green:wan"   eth0
add_led lan1 "green:lan-1" eth1
add_led lan2 "green:lan-2" eth2

uci commit system
/etc/init.d/led enable
/etc/init.d/led start 2>/dev/null || true

exit 0
EOF
    chmod +x files/etc/uci-defaults/99-custom

    cat > files/etc/docker/daemon.json << 'EOF'
{
  "data-root": "/opt/docker",
  "registry-mirrors": ["https://docker.1ms.run"],
  "dns": ["223.5.5.5", "119.29.29.29"],
  "log-driver": "json-file",
  "log-opts": { "max-size": "10m", "max-file": "3" },
  "iptables": true,
  "ip-forward": true,
  "ip-masq": true
}
EOF

    cat > package/base-files/files/etc/profile.d/apk-cheatsheet.sh << 'WELCOME_EOF'
#!/bin/sh
case "$-" in
    *i*) ;;
    *) return 0 ;;
esac
[ -n "$SSH_TTY" ] || [ -t 0 ] || return 0

. /etc/openwrt_release 2>/dev/null
OS_VER="${DISTRIB_RELEASE:-unknown}"

HOST=$(uname -n 2>/dev/null)
KVER=$(uname -r)

LAN_IP=""
command -v uci >/dev/null 2>&1 && LAN_IP=$(uci -q get network.lan.ipaddr 2>/dev/null)
[ -n "$LAN_IP" ] && LAN_IP=${LAN_IP%%/*}
[ -z "$LAN_IP" ] && LAN_IP=$(ip -4 addr show br-lan 2>/dev/null | awk '/inet /{print $2; exit}' | cut -d/ -f1)
[ -z "$LAN_IP" ] && LAN_IP="192.168.3.3"

DOCKER_PATH="/opt/docker"
command -v uci >/dev/null 2>&1 && {
    DR=$(uci -q get dockerd.globals.data_root 2>/dev/null)
    [ -n "$DR" ] && DOCKER_PATH="$DR"
}

if [ -r /proc/uptime ]; then
    US=$(awk '{print int($1)}' /proc/uptime)
    D=$((US/86400)); H=$((US%86400/3600)); M=$((US%3600/60))
    if [ $D -gt 0 ]; then UPTIME="${D}d ${H}h ${M}m"
    elif [ $H -gt 0 ]; then UPTIME="${H}h ${M}m"
    else UPTIME="${M}m"; fi
else UPTIME="-"; fi

TEMP="-"
for z in /sys/class/thermal/thermal_zone*/temp; do
    [ -r "$z" ] || continue
    T=$(cat "$z" 2>/dev/null)
    case "$T" in
        ''|*[!0-9-]*) continue ;;
    esac
    if [ "$T" -gt 0 ]; then
        TEMP="$((T/1000)).$(( (T%1000)/100 ))°C"
        break
    fi
done
if [ "$TEMP" = "-" ]; then
    for h in /sys/class/hwmon/hwmon*/temp1_input; do
        [ -r "$h" ] || continue
        T=$(cat "$h" 2>/dev/null)
        case "$T" in
            ''|*[!0-9-]*) continue ;;
        esac
        if [ "$T" -gt 0 ]; then
            TEMP="$((T/1000)).$(( (T%1000)/100 ))°C"
            break
        fi
    done
fi

if [ -t 1 ]; then
    D='\033[0;90m'
    C='\033[0;36m'
    K='\033[0;33m'
    V='\033[0;37m'
    R='\033[0m'
else
    D=''; C=''; K=''; V=''; R=''
fi

SEP_LEN=49
SEP=$(printf '%.0s─' $(seq 1 $SEP_LEN))

printf "\n"
printf "  ${C}NanoPi R5S${R}  ${D}·${R}  ${V}${HOST}${R}\n"
printf "${D}%s${R}\n" "$SEP"
printf "  ${K}%-6s${R} ${V}%-24s${R} ${K}%-6s${R} ${V}%s${R}\n" \
    "OS"     "OpenWrt ${OS_VER}" "Kernel" "${KVER}"
printf "  ${K}%-6s${R} ${V}%-24s${R} ${K}%-6s${R} ${V}%s${R}\n" \
    "LAN"    "${LAN_IP}" "Uptime" "${UPTIME}"
printf "  ${K}%-6s${R} ${V}%-24s${R} ${K}%-6s${R} ${V}%s${R}\n" \
    "Docker" "${DOCKER_PATH}" "CPU" "${TEMP}"
printf "${D}%s${R}\n" "$SEP"
printf "  ${C}%-30s${R} ${D}%s${R}\n" "apk add <pkg>"               "安装软件包"
printf "  ${C}%-30s${R} ${D}%s${R}\n" "apk del <pkg>"               "卸载软件包"
printf "  ${C}%-30s${R} ${D}%s${R}\n" "apk update && apk upgrade"   "更新全部软件包"
printf "  ${C}%-30s${R} ${D}%s${R}\n" "/etc/init.d/dockerd restart" "重启 Docker 服务"
printf "  ${C}%-30s${R} ${D}%s${R}\n" "df -h ${DOCKER_PATH}"        "查看磁盘占用"
printf "\n"
WELCOME_EOF
    chmod +x package/base-files/files/etc/profile.d/apk-cheatsheet.sh

    : > package/base-files/files/etc/banner
}

pre_build() {
    make target/linux/prepare V=s > /dev/null 2>&1 || true

    local DTS=""
    DTS=$(find build_dir -type f -path "*/arch/arm64/boot/dts/rockchip/rk3568-nanopi-r5s.dts" 2>/dev/null | head -1)
    [ -z "$DTS" ] && DTS=$(find . -type f -path "*/arch/arm64/boot/dts/rockchip/rk3568-nanopi-r5s.dts" 2>/dev/null | head -1)
    [ -z "$DTS" ] && { echo "r5s dts not found, skip"; return 0; }

    echo "DTS: $DTS"

    if grep -q "R5S_FAN_V2" "$DTS"; then
        echo "dts already patched (v2)"; return 0
    fi

    if [ -f "${DTS}.clean" ]; then
        echo "restore DTS from .clean"
        cp "${DTS}.clean" "$DTS"
    elif ! grep -qE "pwm11m0_pins|pwm4_fan_pins|pwm-fan" "$DTS"; then
        echo "backup clean DTS to .clean"
        cp "$DTS" "${DTS}.clean"
    else
        echo "strip old pwm-fan injection"
        awk '
            /^&pwm11 \{/ { in_old=1; next }
            /^&pwm4 \{/  { in_old=1; next }
            in_old && /^\};$/ { in_old=0; next }
            in_old { next }
            { print }
        ' "$DTS" > "$DTS.tmp" && mv "$DTS.tmp" "$DTS"
    fi

    cat >> "$DTS" << 'DTS_EOF'

// ===== R5S_FAN_V2 =====
&pwm0 {
    status = "okay";
    pinctrl-names = "default";
    pinctrl-0 = <&pwm0m0_pins>;
};

/ {
    fan: pwm-fan {
        compatible = "pwm-fan";
        cooling-levels = <0 18 102 170 255>;
        fan-supply = <&vcc5v0_sys>;
        pwms = <&pwm0 0 50000 0>;
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
            cooling-device = <&fan 2 4>;
        };
    };
};
// ===== END R5S_FAN_V2 =====
DTS_EOF
    echo "pwm-fan v2 injected: pwm0 (GPIO0_B7), 50000ns, 5-level"
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
    bc vsftpd sudo unzip file procd logrotate coreutils-stat wireguard-tools python3-light wget-ssl
    bash perl parted curl dosfstools e2fsprogs resize2fs lsblk block-mount blkid
    python3-requests python3-paramiko python3-pytz python3-dateutil python3-bs4
    coreutils-timeout coreutils-date
    "
    for pkg in $ENABLE_PKGS; do
        sed -i "/^# CONFIG_PACKAGE_${pkg} is not set/d" .config
        sed -i "s/^CONFIG_PACKAGE_${pkg}=.*/CONFIG_PACKAGE_${pkg}=y/" .config
        grep -q "^CONFIG_PACKAGE_${pkg}=y" .config || echo "CONFIG_PACKAGE_${pkg}=y" >> .config
    done

    for pkg in clashoo luci-app-clashoo luci-i18n-clashoo-zh-cn kmod-inet-diag \
               luci-app-amlogic luci-lib-nixio \
               luci-app-ttyd ttyd luci-i18n-ttyd-zh-cn \
               luci-app-dockerman luci-lib-docker luci-i18n-dockerman-zh-cn \
               openssh-sftp-server \
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

    sed -i "/^# CONFIG_PACKAGE_kmod-r8125 is not set/d" .config
    sed -i "/^CONFIG_PACKAGE_kmod-r8125=/d" .config
    echo "CONFIG_PACKAGE_kmod-r8125=y" >> .config

    for pkg in kmod-r8169 kmod-r8169-any kmod-r8169-rss; do
        sed -i "s/^CONFIG_PACKAGE_${pkg}=.*/# CONFIG_PACKAGE_${pkg} is not set/" .config
        grep -q "^# CONFIG_PACKAGE_${pkg} is not set" .config || \
          echo "# CONFIG_PACKAGE_${pkg} is not set" >> .config
    done

    sed -i "/^# CONFIG_BUSYBOX_DEFAULT_FEATURE_SH_EXTRA_QUIET is not set/d" .config
    sed -i "/^CONFIG_BUSYBOX_DEFAULT_FEATURE_SH_EXTRA_QUIET=/d" .config
    echo "CONFIG_BUSYBOX_DEFAULT_FEATURE_SH_EXTRA_QUIET=y" >> .config

    local MISSING=0
    for pkg in clashoo luci-app-clashoo kmod-inet-diag luci-app-amlogic luci-app-ttyd ttyd \
               dockerd luci-app-dockerman openssh-sftp-server parted; do
        grep -q "^CONFIG_PACKAGE_${pkg}=y" .config || { echo "missing: $pkg"; MISSING=1; }
    done
    for opt in DOCKER_NET_MACVLAN DOCKER_STO_EXT4; do
        grep -q "^CONFIG_${opt}=y" .config || { echo "missing: $opt"; MISSING=1; }
    done
    grep -q "^CONFIG_PACKAGE_kmod-r8125=y" .config || { echo "missing: kmod-r8125"; MISSING=1; }
    grep -q "^# CONFIG_PACKAGE_kmod-r8169 is not set" .config || { echo "conflict: kmod-r8169 enabled"; MISSING=1; }
    [ $MISSING -eq 1 ] && exit 1

    for f in files/sbin/mountpoint files/etc/rc.local \
             files/etc/init.d/rc.local files/etc/rc.d/S95rc.local \
             files/etc/hotplug.d/net/99-led-netdev \
             files/etc/docker/daemon.json files/etc/uci-defaults/99-custom \
             files/etc/sysctl.d/99-r5s.conf \
             package/base-files/files/etc/profile.d/apk-cheatsheet.sh; do
        [ -e "$f" ] || { echo "missing: $f"; exit 1; }
    done
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