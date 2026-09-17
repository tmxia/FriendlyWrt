#!/usr/bin/env bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PROJECT_DIR="$REPO_ROOT/project"
FRIENDLYWRT_DIR="$PROJECT_DIR/friendlywrt"
SCRIPTS_DIR="$SCRIPT_DIR"

: "${ROOTFS_PARTSIZE:=2048}"
: "${CCACHE_DIR:=$HOME/.ccache}"
: "${CCACHE_MAXSIZE:=3G}"

log()  { echo "[$(date +%H:%M:%S)] $*"; }
warn() { echo "[$(date +%H:%M:%S)] WARN: $*" >&2; }
err()  { echo "[$(date +%H:%M:%S)] ERROR: $*" >&2; exit 1; }

[ -d "$FRIENDLYWRT_DIR" ] || err "friendlywrt 源码目录不存在"
[ -f "$SCRIPTS_DIR/add_packages.sh" ] || err "add_packages.sh 不存在"

step_ccache_and_staging() {
    log "===== 1. ccache + staging_dir 验证 ====="

    mkdir -p "$CCACHE_DIR"
    ccache --max-size="$CCACHE_MAXSIZE"
    ccache --set-config=compression=true
    ccache --set-config=compiler_check=mtime
    ccache --set-config=cache_dir="$CCACHE_DIR"
    ccache -s

    local STAGING="$FRIENDLYWRT_DIR/staging_dir"
    [ -d "$STAGING" ] || { log "staging_dir 不存在（首次编译）"; return 0; }

    local HOST_GCC TC_GCC
    HOST_GCC=$(find "$STAGING/host/bin" -maxdepth 1 -name "*-gcc*" 2>/dev/null | head -1)
    TC_GCC=$(find "$STAGING"/toolchain-*/bin -maxdepth 1 -name "*-gcc" 2>/dev/null | head -1)

    if [ -z "$HOST_GCC" ] || [ -z "$TC_GCC" ]; then
        warn "staging_dir 缓存不完整，删除"
        rm -rf "$STAGING"
    else
        log "[OK] staging_dir 完整"
    fi
}

step_verify_kernel() {
    log "===== 2. 探测内核产物 ====="
    cd "$FRIENDLYWRT_DIR"

    local KVER
    KVER=$(grep -E "^KERNEL_PATCHVER" target/linux/rockchip/Makefile | sed 's/.*[:=]//' | tr -d ' \t')
    log "KERNEL_PATCHVER=${KVER}"

    find target/linux/rockchip -maxdepth 3 \( -type d -name "patches-*" -o -type f -name "config-*" \) 2>/dev/null
}

# 关键：通过软链接把 add_packages.sh 里硬编码的 config-6.1 路径
# 指向真实的 config-6.12。这样无需修改用户的原始脚本，
# add_packages.sh 里的 INET_DIAG 追加就会自动落到 6.12 上。
step_bridge_kernel_config() {
    log "===== 3. 桥接 config-6.1 -> config-6.12（不改 add_packages.sh） ====="
    cd "$FRIENDLYWRT_DIR/target/linux/rockchip" || return 0

    [ -f armv8/config-6.12 ] || err "找不到 armv8/config-6.12"

    if [ -L config-6.1 ]; then
        local target
        target=$(readlink config-6.1)
        if [ "$target" = "armv8/config-6.12" ]; then
            log "[OK] config-6.1 软链接已就位: config-6.1 -> armv8/config-6.12"
        else
            warn "config-6.1 是软链接但指向 $target，重建"
            rm -f config-6.1
            ln -s armv8/config-6.12 config-6.1
        fi
    elif [ -f config-6.1 ]; then
        warn "config-6.1 是真实文件（非软链接），备份为 config-6.1.bak 后重建软链接"
        mv config-6.1 config-6.1.bak
        ln -s armv8/config-6.12 config-6.1
    else
        ln -s armv8/config-6.12 config-6.1
        log "[OK] 已创建软链接 config-6.1 -> armv8/config-6.12"
    fi

    ls -la config-6.1
}

step_clean_legacy_patches() {
    log "===== 3.5 清理历史遗留补丁 ====="
    cd "$FRIENDLYWRT_DIR"

    rm -f target/linux/rockchip/patches-6.12/999-gpio-rockchip-fix-dynamic-base.patch
    rm -f target/linux/rockchip/patches-6.12/998-r5s-dts-led-aliases.patch

    find build_dir -name "*.rej" -path "*gpio-rockchip*" -delete 2>/dev/null || true
    find build_dir -name "*.orig" -path "*gpio-rockchip*" -delete 2>/dev/null || true

    log "[OK] 已清理遗留补丁与 .rej/.orig 文件"
}

step_add_fan_control() {
    log "===== 3.6 添加 PWM 风扇控制 ====="
    cd "$FRIENDLYWRT_DIR"

    mkdir -p files/etc/init.d

    cat > files/etc/init.d/fancontrol << 'EOF'
#!/bin/sh /etc/rc.common

START=95
STOP=10

start() {
    [ -d /sys/class/thermal/thermal_zone0 ] || return
    [ -d /sys/class/pwm/pwmchip0 ] || return
    [ -d /sys/class/pwm/pwmchip0/pwm0 ] || {
        echo 0 > /sys/class/pwm/pwmchip0/export 2>/dev/null
        sleep 1
    }
    echo 10000 > /sys/class/pwm/pwmchip0/pwm0/period 2>/dev/null
    echo 1 > /sys/class/pwm/pwmchip0/pwm0/enable 2>/dev/null
    while true; do
        temp=$(cat /sys/class/thermal/thermal_zone0/temp 2>/dev/null)
        [ -z "$temp" ] && sleep 10 && continue
        temp=$((temp / 1000))
        if [ "$temp" -gt 70 ]; then
            echo 10000 > /sys/class/pwm/pwmchip0/pwm0/duty_cycle 2>/dev/null
        elif [ "$temp" -gt 55 ]; then
            echo 5000 > /sys/class/pwm/pwmchip0/pwm0/duty_cycle 2>/dev/null
        elif [ "$temp" -gt 45 ]; then
            echo 2500 > /sys/class/pwm/pwmchip0/pwm0/duty_cycle 2>/dev/null
        else
            echo 0 > /sys/class/pwm/pwmchip0/pwm0/duty_cycle 2>/dev/null
        fi
        sleep 10
    done
}

stop() {
    echo 0 > /sys/class/pwm/pwmchip0/pwm0/enable 2>/dev/null
}
EOF

    chmod +x files/etc/init.d/fancontrol
    log "[OK] 风扇控制脚本已写入"
}

step_add_led_and_network_fallback() {
    log "===== 3.7 添加 LED 与网络兜底脚本（与 99-custom 兼容） ====="
    cd "$FRIENDLYWRT_DIR"

    mkdir -p files/etc/init.d files/etc/uci-defaults

    # ------------------------------------------------------------------
    # LED 兜底：START=97 晚于 /etc/init.d/led（START=96）。
    # 无论 board.d/01_leds 是否成功、netdev 触发器是否存在，
    # 都用 sysfs 直接绑定 LED；netdev 加载失败时自动降级。
    # 只设置 gpio-leds 里的四个 LED，不碰网卡自身的 LED。
    # ------------------------------------------------------------------
    cat > files/etc/init.d/led-force << 'EOF'
#!/bin/sh /etc/rc.common

START=97
STOP=01

setup_led() {
	local name="$1"
	local trigger="$2"
	local dev="$3"

	[ -e "/sys/class/leds/$name/trigger" ] || return 0

	if ! echo "$trigger" > "/sys/class/leds/$name/trigger" 2>/dev/null; then
		echo heartbeat > "/sys/class/leds/$name/trigger" 2>/dev/null || \
		echo default-on > "/sys/class/leds/$name/trigger" 2>/dev/null
		return 0
	fi

	[ -n "$dev" ] && [ -e "/sys/class/leds/$name/device_name" ] && {
		echo "$dev" > "/sys/class/leds/$name/device_name" 2>/dev/null
		[ -e "/sys/class/leds/$name/link" ] && echo 1 > "/sys/class/leds/$name/link" 2>/dev/null
		[ -e "/sys/class/leds/$name/tx" ]   && echo 1 > "/sys/class/leds/$name/tx"   2>/dev/null
		[ -e "/sys/class/leds/$name/rx" ]   && echo 1 > "/sys/class/leds/$name/rx"   2>/dev/null
	}
}

start() {
	local i
	for i in $(seq 1 60); do
		[ -e /sys/class/net/eth0 ] && break
		sleep 1
	done

	# 电源 LED 用 heartbeat，DTS 里没有 default-trigger
	setup_led "red:power"  heartbeat ""

	# 网络 LED 用 netdev；DTS 中的名称由 color+function[-enumerator] 决定
	setup_led "green:wan"   netdev eth0
	setup_led "green:lan-1" netdev eth1
	setup_led "green:lan-2" netdev eth2

	# 兼容可能的不同内核命名
	[ -e /sys/class/leds/green:lan/trigger ] && setup_led "green:lan" netdev eth1
	[ -e /sys/class/leds/red:power/trigger ] && setup_led "red:power" heartbeat ""
}

boot() { start; }
EOF
    chmod +x files/etc/init.d/led-force

    # ------------------------------------------------------------------
    # 网络兜底：命名 50-fix-network，字典序早于 99-custom 执行。
    # 只补 ifname / proto，不设置 IP / gateway / dns / netmask，
    # 那些参数由 add_packages.sh 的 99-custom 负责。
    # 判断条件检查 ifname 是否为空（而不是 section 是否存在），
    # 避免被 99-custom 中先执行的 `uci set network.lan.ipaddr` 骗过。
    # ------------------------------------------------------------------
    cat > files/etc/uci-defaults/50-fix-network << 'EOF'
#!/bin/sh

if [ -z "$(uci -q get network.lan.ifname)" ] && \
   [ "$(uci -q get network.lan.type)" != "bridge" ]; then
	uci -q set network.lan=interface
	uci -q set network.lan.type='bridge'
	uci -q set network.lan.ifname='eth1 eth2'
	uci -q set network.lan.proto='static'
	uci -q set network.lan.ipaddr='192.168.3.3'
	uci -q set network.lan.netmask='255.255.255.0'
	uci commit network
fi

if [ -z "$(uci -q get network.wan.ifname)" ]; then
	uci -q set network.wan=interface
	uci -q set network.wan.ifname='eth0'
	uci -q set network.wan.proto='dhcp'
	uci commit network
fi

exit 0
EOF
    chmod +x files/etc/uci-defaults/50-fix-network

    log "[OK] LED 与网络兜底脚本已写入（50-fix-network 兼容 99-custom）"
}

step_init_config() {
    log "===== 4. 初始化 .config ====="
    cd "$FRIENDLYWRT_DIR"
    cat > .config <<EOF
CONFIG_TARGET_rockchip=y
CONFIG_TARGET_rockchip_armv8=y
CONFIG_TARGET_rockchip_armv8_DEVICE_friendlyarm_nanopi-r5s=y
CONFIG_LUCI_LANG_zh_Hans=y
CONFIG_CCACHE=y
CONFIG_CCACHE_DIR="$CCACHE_DIR"
CONFIG_TARGET_ROOTFS_PARTSIZE=$ROOTFS_PARTSIZE

CONFIG_PACKAGE_docker=y
CONFIG_PACKAGE_dockerd=y
CONFIG_PACKAGE_docker-compose=y
CONFIG_PACKAGE_luci-app-dockerman=y
CONFIG_PACKAGE_luci-i18n-dockerman-zh-cn=y
CONFIG_PACKAGE_luci-lib-docker=y
CONFIG_DOCKER_NET_OVERLAY=y

CONFIG_PACKAGE_luci-app-amlogic=y
CONFIG_PACKAGE_luci-lib-nixio=y
CONFIG_PACKAGE_block-mount=y
CONFIG_PACKAGE_blkid=y
CONFIG_PACKAGE_parted=y
CONFIG_PACKAGE_dosfstools=y
CONFIG_PACKAGE_e2fsprogs=y
CONFIG_PACKAGE_jq=y
CONFIG_PACKAGE_lsblk=y
CONFIG_PACKAGE_pv=y
CONFIG_PACKAGE_losetup=y
CONFIG_PACKAGE_uuidgen=y
CONFIG_PACKAGE_bash=y
CONFIG_PACKAGE_perl=y
CONFIG_PACKAGE_fdisk=y

# ==== 内核 GPIO / LED ====
CONFIG_KERNEL_GPIO_ROCKCHIP=y
CONFIG_KERNEL_PINCTRL_ROCKCHIP=y
CONFIG_KERNEL_NEW_LEDS=y
CONFIG_KERNEL_LEDS_CLASS=y
CONFIG_KERNEL_LEDS_GPIO=y
CONFIG_KERNEL_LEDS_TRIGGERS=y
CONFIG_KERNEL_LEDS_TRIGGER_HEARTBEAT=y
CONFIG_KERNEL_LEDS_TRIGGER_NETDEV=y
CONFIG_KERNEL_LEDS_TRIGGER_TIMER=y
CONFIG_KERNEL_LEDS_TRIGGER_DEFAULT_ON=y
CONFIG_KERNEL_LEDS_TRIGGER_TRANSIENT=y

# ==== 网络驱动（RTL8125 走 PCIe，RGMII PHY 走 stmmac） ====
CONFIG_KERNEL_R8169=y
CONFIG_KERNEL_STMMAC_ETH=y
CONFIG_KERNEL_DWMAC_ROCKCHIP=y
CONFIG_KERNEL_PHY_ROCKCHIP_NANENG_COMBO_PHY=y
CONFIG_KERNEL_PHY_ROCKCHIP_SNPS_PCIE3=y
CONFIG_KERNEL_PCIE_ROCKCHIP_HOST=y
CONFIG_KERNEL_REALTEK_PHY=y

# ==== 热管理与 PWM 风扇 ====
CONFIG_KERNEL_ROCKCHIP_THERMAL=y
CONFIG_KERNEL_PWM_ROCKCHIP=y
CONFIG_KERNEL_PWM_FAN=y

# ==== USB ====
CONFIG_KERNEL_USB_EHCI_HCD=y
CONFIG_KERNEL_USB_EHCI_PCI=y
CONFIG_KERNEL_USB_OHCI_HCD=y
CONFIG_KERNEL_USB_UHCI_HCD=y
CONFIG_KERNEL_USB_XHCI_HCD=y
CONFIG_KERNEL_USB_XHCI_PCI=y

# ==== Docker / 容器支持 ====
CONFIG_KERNEL_CGROUPS=y
CONFIG_KERNEL_CGROUP_FREEZER=y
CONFIG_KERNEL_CGROUP_PIDS=y
CONFIG_KERNEL_CGROUP_DEVICE=y
CONFIG_KERNEL_CPUSETS=y
CONFIG_KERNEL_MEMCG=y
CONFIG_KERNEL_CGROUP_BPF=y
CONFIG_KERNEL_NAMESPACES=y
CONFIG_KERNEL_OVERLAY_FS=y
CONFIG_KERNEL_BRIDGE=y
CONFIG_KERNEL_VETH=y
CONFIG_KERNEL_NF_NAT=y
CONFIG_KERNEL_IP_NF_NAT=y
CONFIG_KERNEL_NETFILTER_XT_MATCH_ADDRTYPE=y
EOF

    yes "" 2>/dev/null | make oldconfig > /dev/null 2>&1
    log "[OK] .config 初始化完成"
}

step_apply_customizations() {
    log "===== 5. 应用自定义配置（调用 add_packages.sh，不修改脚本本身） ====="

    log "克隆 luci-app-amlogic..."
    rm -rf "$FRIENDLYWRT_DIR/package/luci-app-amlogic"
    git clone --depth 1 -b main \
        https://github.com/ophub/luci-app-amlogic.git \
        "$FRIENDLYWRT_DIR/package/luci-app-amlogic" 2>&1 | tail -1

    cd "$FRIENDLYWRT_DIR"
    make defconfig > /dev/null 2>&1
    sed -i '/^# CONFIG_PACKAGE_luci-app-amlogic is not set/d' .config
    sed -i '/^CONFIG_PACKAGE_luci-app-amlogic=/d' .config
    echo "CONFIG_PACKAGE_luci-app-amlogic=y" >> .config
    yes "" 2>/dev/null | make oldconfig > /dev/null 2>&1

    cd "$PROJECT_DIR"
    bash "$SCRIPTS_DIR/add_packages.sh"
    log "[OK] add_packages.sh 执行完成（未修改原脚本）"
}

step_dedupe_config() {
    log "===== 6. .config 去重 ====="
    cd "$FRIENDLYWRT_DIR"
    local before after
    before=$(wc -l < .config)
    awk -F= '
      /^# / { print; next }
      /^CONFIG_/ {
        key = $1
        if (!(key in seen)) { keys[++n] = key; seen[key] = 1 }
        values[key] = $0
        next
      }
      { print }
      END { for (i = 1; i <= n; i++) print values[keys[i]] }
    ' .config > .config.dedup && mv .config.dedup .config
    after=$(wc -l < .config)
    log "[OK] 去重: $before → $after"
}

step_patch_file_makefile() {
    log "===== 7. 修补 file Makefile ====="
    cd "$FRIENDLYWRT_DIR"

    local FILE_MK="feeds/packages/libs/file/Makefile"
    [ -f "$FILE_MK" ] || { log "跳过（$FILE_MK 不存在）"; return 0; }

    python3 - "$FILE_MK" << 'PY'
import re, sys, pathlib
p = pathlib.Path(sys.argv[1])
txt = p.read_text()
m = re.search(r'(define Package/libmagic\b.*?DEPENDS:=)([^\n]*)', txt, flags=re.S)
if not m: sys.exit(0)
deps = m.group(2)
if '+libbz2' not in deps or '+liblzma' not in deps:
    deps += " +libbz2 +liblzma"
    p.write_text(txt[:m.start(2)] + deps + txt[m.end(2):])
PY

    for sym in PACKAGE_libbz2 PACKAGE_liblzma PACKAGE_zlib; do
        sed -i "/^# CONFIG_${sym} is not set/d; /^CONFIG_${sym}=/d" .config
        echo "CONFIG_${sym}=y" >> .config
    done
    yes "" 2>/dev/null | make oldconfig > /dev/null 2>&1
    log "[OK] file Makefile 已修补"
}

step_force_config() {
    log "===== 8. 强制修正关键配置 ====="
    cd "$FRIENDLYWRT_DIR"

    sed -i '/^CONFIG_CCACHE_DIR=/d' .config
    echo "CONFIG_CCACHE_DIR=\"$CCACHE_DIR\"" >> .config
    sed -i '/^CONFIG_CCACHE=/d' .config
    echo "CONFIG_CCACHE=y" >> .config
    sed -i '/^CONFIG_TARGET_ROOTFS_PARTSIZE=/d' .config
    echo "CONFIG_TARGET_ROOTFS_PARTSIZE=$ROOTFS_PARTSIZE" >> .config

    local pkg
    for pkg in docker dockerd docker-compose luci-app-dockerman luci-i18n-dockerman-zh-cn luci-lib-docker \
               luci-app-amlogic luci-lib-nixio block-mount blkid parted dosfstools e2fsprogs jq lsblk pv losetup uuidgen bash perl fdisk; do
        sed -i "/^CONFIG_PACKAGE_${pkg}=/d" .config
        echo "CONFIG_PACKAGE_${pkg}=y" >> .config
    done

    # 强制重新声明 LED / 网络驱动内核选项，防止被 add_packages.sh 覆盖
    local kopt
    for kopt in \
        CONFIG_KERNEL_LEDS_GPIO \
        CONFIG_KERNEL_LEDS_TRIGGERS \
        CONFIG_KERNEL_LEDS_TRIGGER_HEARTBEAT \
        CONFIG_KERNEL_LEDS_TRIGGER_NETDEV \
        CONFIG_KERNEL_LEDS_TRIGGER_TIMER \
        CONFIG_KERNEL_LEDS_TRIGGER_DEFAULT_ON \
        CONFIG_KERNEL_R8169 \
        CONFIG_KERNEL_STMMAC_ETH \
        CONFIG_KERNEL_DWMAC_ROCKCHIP; do
        sed -i "/^${kopt}=/d" .config
        echo "${kopt}=y" >> .config
    done

    log "[OK] 关键配置已强制修正"
}

step_download_packages() {
    log "===== 9. 下载软件包源码 ====="
    cd "$FRIENDLYWRT_DIR"
    rm -rf dl/go-mod-cache

    make download -j"$(nproc)" > /dev/null 2>&1 || true
    find dl -type f -size -1024c -delete 2>/dev/null || true
    make download -j"$(nproc)" > /dev/null 2>&1 || true
    log "[OK] dl: $(find dl -type f | wc -l) 文件"
}

step_sync_config() {
    log "===== 9.5 同步 .config 与内核 Kconfig ====="
    cd "$FRIENDLYWRT_DIR"

    rm -rf tmp/.config-* tmp/.packageinfo tmp/.targetinfo 2>/dev/null || true

    yes "" 2>/dev/null | make oldconfig > /dev/null 2>&1 || true
    make defconfig > /dev/null 2>&1 || true
    yes "" 2>/dev/null | make oldconfig > /dev/null 2>&1 || true

    log "执行 make kernel_oldconfig（解压内核源码）..."
    if ! make kernel_oldconfig > /tmp/kernel_oldconfig.log 2>&1; then
        tail -80 /tmp/kernel_oldconfig.log
        err "make kernel_oldconfig 失败"
    fi

    log "[OK] 内核配置同步完成"
}

step_verify_kernel_options() {
    log "===== 9.6 校验关键内核选项 ====="
    cd "$FRIENDLYWRT_DIR"

    local KSRC
    KSRC=$(find build_dir -maxdepth 5 -type d -name "linux-6.12*" 2>/dev/null | head -1)

    if [ -z "$KSRC" ] || [ ! -f "$KSRC/.config" ]; then
        warn "未找到已解压的内核源码 .config，跳过校验"
        return 0
    fi

    log "内核源码路径: $KSRC"
    log "--- LED / 网络驱动关键配置 ---"

    local failed=0
    local opt
    for opt in \
        CONFIG_LEDS_GPIO \
        CONFIG_LEDS_TRIGGER_NETDEV \
        CONFIG_LEDS_TRIGGER_HEARTBEAT \
        CONFIG_LEDS_TRIGGER_TIMER \
        CONFIG_LEDS_TRIGGER_DEFAULT_ON \
        CONFIG_R8169 \
        CONFIG_STMMAC_ETH \
        CONFIG_DWMAC_ROCKCHIP; do
        if grep -q "^${opt}=y" "$KSRC/.config"; then
            log "  [OK]   $opt"
        elif grep -q "^${opt}=m" "$KSRC/.config"; then
            log "  [MOD]  $opt"
        else
            warn "  [MISS] $opt"
            failed=$((failed + 1))
        fi
    done

    log "--- INET_DIAG 系列（add_packages.sh 追加） ---"
    for opt in \
        CONFIG_INET_DIAG \
        CONFIG_INET_TCP_DIAG \
        CONFIG_INET_UDP_DIAG \
        CONFIG_INET_RAW_DIAG; do
        if grep -q "^${opt}=y" "$KSRC/.config"; then
            log "  [OK]   $opt"
        elif grep -q "^${opt}=m" "$KSRC/.config"; then
            log "  [MOD]  $opt"
        else
            warn "  [MISS] $opt"
        fi
    done

    if [ "$failed" -gt 0 ]; then
        warn "有 $failed 个关键 LED/网络选项未启用，LED 可能不工作"
    else
        log "[OK] 所有关键 LED/网络内核选项均已启用"
    fi
}

step_compile() {
    log "===== 10. 分阶段编译 ====="
    cd "$FRIENDLYWRT_DIR"

    step_sync_config
    step_verify_kernel_options

    local s
    for s in tools/compile toolchain/compile target/compile package/compile; do
        log "---- STAGE: $s ----"
        make -j"$(nproc)" "$s" > "/tmp/build_${s//\//_}.log" 2>&1 \
            || { tail -100 "/tmp/build_${s//\//_}.log"; err "编译失败: $s"; }
        log "[DONE] $s"
    done

    log "---- STAGE: final make ----"
    make -j"$(nproc)" > /tmp/build_final.log 2>&1 \
        || { tail -100 /tmp/build_final.log; err "final make 失败"; }
    log "[DONE] final make"

    ls -lh bin/targets/rockchip/armv8/*.img.gz
}

main() {
    log "ImmortalWrt R5S 编译脚本启动"

    step_ccache_and_staging
    step_verify_kernel
    step_bridge_kernel_config
    step_clean_legacy_patches
    step_add_fan_control
    step_add_led_and_network_fallback
    step_init_config
    step_apply_customizations
    step_dedupe_config
    step_patch_file_makefile
    step_force_config
    step_download_packages
    step_compile

    log "全部步骤完成"
}

main "$@"