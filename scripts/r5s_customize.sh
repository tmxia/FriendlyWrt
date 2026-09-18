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

    # 首启挂载 p3 为 /opt（编译时已加好 p3 分区，这里只做 mkfs + mount + fstab）
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

# 格式化（若是空盘或非 ext4）
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

# 注入 R5S 风扇 dts（温控点 40/45℃，与原脚本一致）
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

    echo "✅ 已注入 pwm-fan 节点（GPIO0_C3 = PWM4_M1，40℃→1档，45℃→2档）"
}

# 编译完成后：给 sdcard.img 的 GPT 加上 p3=/opt（last_lba=max，内核自动截断到实际盘大小）
# 全流程使用 Python gzip，彻底避开 shell gzip 对 trailing garbage 的 exit code 2
add_opt_partition() {
    echo "===== Post-build: 给 image 添加 p3=/opt 分区 ====="

    local OUT="bin/targets/rockchip/armv8"
    local IMG
    IMG=$(find "$OUT" -maxdepth 1 -name "*nanopi-r5s-ext4-sysupgrade.img.gz" -type f 2>/dev/null | head -1)
    [ -z "$IMG" ] && { echo "⚠️ 未找到 sdcard img，跳过"; return 0; }
    echo "目标: $IMG"

    python3 - "$IMG" << 'PYEOF'
import gzip, shutil, struct, zlib, sys, os, tempfile

img_gz = sys.argv[1]
tmp_img = tempfile.mktemp(suffix='.img')

# ---- 1) Python gzip 解压（忽略 trailing garbage） ----
try:
    with gzip.open(img_gz, 'rb') as f_in:
        with open(tmp_img, 'wb') as f_out:
            shutil.copyfileobj(f_in, f_out)
except Exception as e:
    print(f"ERROR: 解压失败: {e}")
    try: os.unlink(tmp_img)
    except: pass
    sys.exit(0)

if not os.path.exists(tmp_img) or os.path.getsize(tmp_img) == 0:
    print("ERROR: 解压为空")
    try: os.unlink(tmp_img)
    except: pass
    sys.exit(0)

print(f"解压完成: {os.path.getsize(tmp_img)} 字节")

# ---- 2) 修改 GPT ----
with open(tmp_img, 'r+b') as f:
    f.seek(512)
    header = bytearray(f.read(92))
    if header[:8] != b'EFI PART':
        print("ERROR: not a GPT image")
        f.close()
        os.unlink(tmp_img)
        sys.exit(0)

    f.seek(1024)
    entries = bytearray(f.read(128 * 128))

    # p3 = index 2
    p3_off = 2 * 128
    if entries[p3_off:p3_off+16] != b'\x00' * 16:
        print("p3 已存在，跳过")
        f.close()
        os.unlink(tmp_img)
        sys.exit(0)

    p2_off = 1 * 128
    p2_last = struct.unpack('<Q', entries[p2_off+40:p2_off+48])[0]
    print(f"p2 last_lba = {p2_last}")

    p3_first = ((p2_last + 1 + 2047) // 2048) * 2048
    p3_last = 0xFFFFFFFFFFFFFFFF
    print(f"p3 first={p3_first}, last=max (内核自动截断)")

    # Linux filesystem GUID（小端序）
    p3_type = bytes.fromhex('af3dc60f838472478e793d69d8477de4')
    p3_uuid = bytes.fromhex('8f3c4a1e5b2d4f7e9a1c3e5f7a9b1d3f')

    entries[p3_off:p3_off+16] = p3_type
    entries[p3_off+16:p3_off+32] = p3_uuid
    entries[p3_off+32:p3_off+40] = struct.pack('<Q', p3_first)
    entries[p3_off+40:p3_off+48] = struct.pack('<Q', p3_last)
    name = "opt".encode('utf-16-le')
    entries[p3_off+56:p3_off+56+len(name)] = name

    # header last_usable_lba 设为 max-33
    header[48:56] = struct.pack('<Q', 0xFFFFFFFFFFFFFFFF - 33)

    entries_crc = zlib.crc32(entries) & 0xFFFFFFFF
    header[88:92] = struct.pack('<I', entries_crc)

    header[16:20] = b'\x00\x00\x00\x00'
    header_crc = zlib.crc32(header) & 0xFFFFFFFF
    header[16:20] = struct.pack('<I', header_crc)

    f.seek(512); f.write(header)
    f.seek(1024); f.write(entries)
    print("GPT p3 added")

# ---- 3) Python gzip 重新压缩，覆盖原文件 ----
try:
    with open(tmp_img, 'rb') as f_in:
        with gzip.open(img_gz, 'wb', compresslevel=9) as f_out:
            shutil.copyfileobj(f_in, f_out)
    print("✅ 压缩完成")
except Exception as e:
    print(f"ERROR: 压缩失败: {e}")
    try: os.unlink(tmp_img)
    except: pass
    sys.exit(0)

os.unlink(tmp_img)
PYEOF

    echo "✅ p3=/opt 已加入 GPT（刷盘后内核按实际容量截断）"
    ls -lh "$IMG"
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

    # 确保必需包被启用（r5s.config 里未必全列全）
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

    # 关键功能包（含 Docker 生态、SFTP、内核模块）
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

    # 屏蔽 legacy iptables（可能被 dnsmasq-full / firewall4 依赖间接拉入）
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

    # 在 config_stage 中重新计算内核 config 路径（KERNEL_CONFIG_FILE 是 post_feeds 的局部变量）
    local KV
    KV=$(grep '^KERNEL_PATCHVER' target/linux/rockchip/Makefile 2>/dev/null | cut -d= -f2 | tr -d ' ')
    [ -z "$KV" ] && KV="6.12"
    echo "===== 风扇/PWM 内核 ====="
    grep -E "^CONFIG_(PWM|PWM_SYSFS|PWM_ROCKCHIP|SENSORS_PWM_FAN)=" "target/linux/rockchip/config-${KV}" 2>/dev/null || echo "  (无)"

    echo "===== mountpoint ====="
    [ -f files/sbin/mountpoint ] && echo "[OK] shell 版已打包" || echo "[FAIL] 未找到 files/sbin/mountpoint"

    echo "===== resize2fs ====="
    grep -E "^CONFIG_PACKAGE_resize2fs=y" .config || echo "  (无)"
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