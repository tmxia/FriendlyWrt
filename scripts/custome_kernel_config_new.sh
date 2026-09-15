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

resolve_kconfig() {
    local cand
    for cand in \
        "target/linux/rockchip/armv8/config-6.12" \
        "target/linux/rockchip/config-6.12"; do
        if [ -f "$cand" ]; then
            echo "$cand"
            return 0
        fi
    done
    echo ""
    return 1
}

resolve_r5s_dts() {
    local cand
    for cand in \
        "target/linux/rockchip/armv8/base-files/arch/arm64/boot/dts/rockchip/rk3568-nanopi-r5s.dts" \
        "target/linux/rockchip/files/arch/arm64/boot/dts/rockchip/rk3568-nanopi-r5s.dts" \
        "target/linux/rockchip/armv8/base-files/arch/arm64/boot/dts/rockchip/rk3568-nanopi-r5s.dtsi"; do
        if [ -f "$cand" ]; then
            echo "$cand"
            return 0
        fi
    done
    echo ""
    return 1
}

step_ccache_and_staging() {
    log "===== 1. ccache + staging_dir 验证 ====="

    mkdir -p "$CCACHE_DIR"
    ccache --max-size="$CCACHE_MAXSIZE"
    ccache --set-config=compression=true
    ccache --set-config=compiler_check=mtime
    ccache --set-config=cache_dir="$CCACHE_DIR"
    ccache -s

    local STAGING="$FRIENDLYWRT_DIR/staging_dir"
    [ -d "$STAGING" ] || { log "staging_dir 不存在（首次编译）"; return; }

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

step_bridge_kernel_config() {
    log "===== 3. 桥接 config-6.1 -> config-6.12 ====="
    cd "$FRIENDLYWRT_DIR/target/linux/rockchip" || return

    [ -f armv8/config-6.12 ] || err "找不到 armv8/config-6.12"
    [ -e config-6.1 ] || ln -s armv8/config-6.12 config-6.1
    ls -la config-6.1
}

step_patch_gpio() {
    log "===== 3.5 修复 Rockchip GPIO 动态基地址 ====="
    cd "$FRIENDLYWRT_DIR"

    local PATCH_DIR="target/linux/rockchip/patches-6.12"
    mkdir -p "$PATCH_DIR"

    local GPIO_PATCH="$PATCH_DIR/999-gpio-rockchip-fix-dynamic-base.patch"

    if [ -f "$GPIO_PATCH" ]; then
        log "GPIO 修复补丁已存在，跳过"
        return
    fi

    cat > "$GPIO_PATCH" << 'PATCH_EOF'
--- a/drivers/gpio/gpio-rockchip.c
+++ b/drivers/gpio/gpio-rockchip.c
@@ -108,7 +108,7 @@ static int rockchip_gpio_probe(struct platform_device *pdev)
 	bank->gpio_chip.parent = &pdev->dev;
 	bank->gpio_chip.of_node = pdev->dev.of_node;
 	bank->gpio_chip.ngpio = bank->nr_pins;
-	bank->gpio_chip.base = -1;
+	bank->gpio_chip.base = bank->pin_base;
 
 	gc = &bank->gpio_chip;
 	ret = devm_gpiochip_add_data(&pdev->dev, gc, bank);
PATCH_EOF

    log "[OK] GPIO 驱动修复补丁已写入: $GPIO_PATCH"
}

step_fix_led_dts() {
    log "===== 3.6 修正 R5S LED 设备树 ====="
    cd "$FRIENDLYWRT_DIR"

    local DTS_FILE
    DTS_FILE=$(resolve_r5s_dts)

    if [ -z "$DTS_FILE" ]; then
        warn "未找到 R5S DTS 文件，跳过 DTS 修改"
        return
    fi

    log "找到 DTS: $DTS_FILE"

    if ! grep -q "led-boot" "$DTS_FILE"; then
        python3 - "$DTS_FILE" << 'PYEOF'
import sys, re, pathlib
p = pathlib.Path(sys.argv[1])
txt = p.read_text()
if 'led-boot' in txt:
    sys.exit(0)
aliases_block = '''
	aliases {
		led-boot = &sys_led;
		led-failsafe = &sys_led;
		led-running = &sys_led;
		led-upgrade = &sys_led;
	};
'''
m = re.search(r'^/\s*\{', txt, flags=re.M)
if m:
    insert_pos = txt.index('{', m.start()) + 1
    txt = txt[:insert_pos] + aliases_block + txt[insert_pos:]
    p.write_text(txt)
    print("[OK] 已插入 LED aliases")
else:
    print("[WARN] 未找到顶层 / 节点，跳过 aliases 插入")
PYEOF
    else
        log "LED aliases 已存在"
    fi

    sed -i 's|linux,default-trigger = "default-on"|linux,default-trigger = "heartbeat"|g' "$DTS_FILE" || true
    sed -i 's|linux,default-trigger = "netdev"|linux,default-trigger = "none"|g' "$DTS_FILE" || true

    log "[OK] LED 触发器配置已修正"
}

step_patch_kconfig() {
    log "===== 3.7 补齐内核 Kconfig 选项 ====="
    cd "$FRIENDLYWRT_DIR"

    local KCONFIG
    KCONFIG=$(resolve_kconfig)

    if [ -z "$KCONFIG" ]; then
        warn "未找到 config-6.12，跳过 Kconfig 补齐"
        return
    fi

    local opt
    for opt in \
        CONFIG_GPIO_ROCKCHIP \
        CONFIG_PINCTRL_ROCKCHIP \
        CONFIG_LEDS_GPIO \
        CONFIG_LEDS_TRIGGER_HEARTBEAT \
        CONFIG_PHY_ROCKCHIP_NANENG_COMBO_PHY \
        CONFIG_PHY_ROCKCHIP_SNPS_PCIE3 \
        CONFIG_PCIE_ROCKCHIP_HOST \
        CONFIG_ROCKCHIP_THERMAL \
        CONFIG_PWM_ROCKCHIP \
        CONFIG_PWM_FAN \
        CONFIG_USB_EHCI_HCD \
        CONFIG_USB_EHCI_PCI \
        CONFIG_USB_OHCI_HCD \
        CONFIG_USB_UHCI_HCD \
        CONFIG_USB_XHCI_HCD \
        CONFIG_USB_XHCI_PCI \
        CONFIG_CGROUPS \
        CONFIG_CGROUP_FREEZER \
        CONFIG_CGROUP_PIDS \
        CONFIG_CGROUP_DEVICE \
        CONFIG_CPUSETS \
        CONFIG_MEMCG \
        CONFIG_CGROUP_BPF \
        CONFIG_NAMESPACES \
        CONFIG_OVERLAY_FS \
        CONFIG_BRIDGE \
        CONFIG_VETH \
        CONFIG_NF_NAT \
        CONFIG_IP_NF_NAT \
        CONFIG_NETFILTER_XT_MATCH_ADDRTYPE; do
        if ! grep -q "^${opt}=y" "$KCONFIG"; then
            sed -i "/^${opt}=/d" "$KCONFIG"
            sed -i "/^# ${opt} is not set/d" "$KCONFIG"
            echo "${opt}=y" >> "$KCONFIG"
        fi
    done

    for opt in \
        CONFIG_LEDS_TRIGGER_NETDEV \
        CONFIG_LEDS_TRIGGER_DEFAULT_ON \
        CONFIG_LEDS_TRIGGER_TIMER \
        CONFIG_LEDS_TRIGGER_TRANSIENT; do
        if ! grep -q "^${opt} is not set" "$KCONFIG"; then
            sed -i "/^${opt}=/d" "$KCONFIG"
            echo "# ${opt} is not set" >> "$KCONFIG"
        fi
    done

    log "[OK] 内核 Kconfig 选项已补齐"
}

step_add_fan_control() {
    log "===== 3.8 添加 PWM 风扇控制 ====="
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
EOF

    yes "" 2>/dev/null | make oldconfig > /dev/null 2>&1
    log "[OK] .config 初始化完成"
}

step_apply_customizations() {
    log "===== 5. 应用自定义配置 ====="

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

    sed -i 's|target/linux/rockchip/config-\${KERNEL_VERSION}|target/linux/rockchip/armv8/config-\${KERNEL_VERSION}|' \
        "$SCRIPTS_DIR/add_packages.sh"

    cd "$PROJECT_DIR"
    bash "$SCRIPTS_DIR/add_packages.sh"
    log "[OK] add_packages.sh 执行完成"
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
    [ -f "$FILE_MK" ] || { log "跳过（$FILE_MK 不存在）"; return; }

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

step_compile() {
    log "===== 10. 分阶段编译 ====="
    cd "$FRIENDLYWRT_DIR"

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
    step_patch_gpio
    step_fix_led_dts
    step_patch_kconfig
    step_add_fan_control
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