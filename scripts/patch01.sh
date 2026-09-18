#!/bin/bash
# patch01.sh - CVE-2026-23368 PHY LED trigger AB-BA 死锁修复
# 将 phy_led_triggers_register/unregister 从 phy_attach_direct/phy_detach
# 移到 phy_probe/phy_remove，避开 RTNL 与 triggers_list_lock 的锁序冲突
set -e

KERNEL_SRC="$1"

if [ -z "$KERNEL_SRC" ]; then
    KERNEL_SRC=$(find build_dir -maxdepth 4 -type d -path "*/linux-rockchip_armv8/linux-*" 2>/dev/null | head -1)
    [ -z "$KERNEL_SRC" ] && KERNEL_SRC=$(find . -maxdepth 6 -type d -path "*/linux-rockchip_armv8/linux-*" 2>/dev/null | head -1)
fi

if [ -z "$KERNEL_SRC" ] || [ ! -d "$KERNEL_SRC" ]; then
    echo "❌ 未找到内核源码目录"
    exit 1
fi

echo "内核源码: $KERNEL_SRC"

python3 - "$KERNEL_SRC" << 'PYEOF'
import sys, os

src = sys.argv[1]
dev_c = os.path.join(src, 'drivers/net/phy/phy_device.c')

if not os.path.exists(dev_c):
    print('❌ 未找到 phy_device.c')
    sys.exit(1)

with open(dev_c, 'r') as f:
    c = f.read()

# 幂等检查
if 'out_unreg_led:' in c:
    print('✅ CVE-2026-23368 已应用，跳过')
    sys.exit(0)

if 'phy_led_triggers_register' not in c:
    print('⚠️ 未找到 phy_led_triggers_register，内核可能未编译 LED_TRIGGER_PHY')
    sys.exit(0)

changes = 0
total = 7

# --- 1) phy_probe 声明处加 int ret; ---
old1 = '\tstruct phy_driver *phydrv = to_phy_driver(drv);\n\n\tphydev->drv = phydrv;'
new1 = '\tstruct phy_driver *phydrv = to_phy_driver(drv);\n\tint ret;\n\n\tphydev->drv = phydrv;'
if old1 in c:
    c = c.replace(old1, new1, 1)
    changes += 1
    print('✅ [1/7] phy_probe 加 int ret;')
else:
    print('⚠️ [1/7] 未找到声明锚点')

# --- 2) phy_probe: mutex_lock 前插入 LED 注册 ---
old2 = ('\tif (phydrv->flags & PHY_IS_INTERNAL)\n'
        '\t\tphydev->is_internal = true;\n\n'
        '\tmutex_lock(&phydev->lock);')
new2 = ('\tif (phydrv->flags & PHY_IS_INTERNAL)\n'
        '\t\tphydev->is_internal = true;\n\n'
        '\t/* CVE-2026-23368: register LED triggers during probe (RTNL not held) */\n'
        '\tif (IS_ENABLED(CONFIG_LED_TRIGGER_PHY)) {\n'
        '\t\tret = phy_led_triggers_register(phydev);\n'
        '\t\tif (ret)\n'
        '\t\t\treturn ret;\n'
        '\t}\n\n'
        '\tmutex_lock(&phydev->lock);')
if old2 in c:
    c = c.replace(old2, new2, 1)
    changes += 1
    print('✅ [2/7] phy_probe 插入 LED 注册')
else:
    print('⚠️ [2/7] 未找到 PHY_IS_INTERNAL 锚点')

# --- 3) phy_probe: 修改 probe 调用的错误处理 ---
old3 = ('\tif (phydev->drv->probe) {\n'
        '\t\terr = phydev->drv->probe(phydev);\n'
        '\t\tif (err)\n'
        '\t\t\tgoto out;\n'
        '\t}\n')
new3 = ('\tif (phydev->drv->probe) {\n'
        '\t\tret = phydev->drv->probe(phydev);\n'
        '\t\tif (ret)\n'
        '\t\t\tgoto out_unreg_led;\n'
        '\t}\n')
if old3 in c:
    c = c.replace(old3, new3, 1)
    changes += 1
    print('✅ [3/7] phy_probe 修改错误处理')
else:
    print('⚠️ [3/7] 未找到 probe 调用锚点')

# --- 4) phy_probe: 加 out_unreg_led 标签 ---
old4 = ('out:\n'
        '\tmutex_unlock(&phydev->lock);\n\n'
        '\treturn err;\n'
        '}')
new4 = ('out:\n'
        '\tmutex_unlock(&phydev->lock);\n\n'
        '\treturn err;\n'
        '\n'
        'out_unreg_led:\n'
        '\tmutex_unlock(&phydev->lock);\n'
        '\tif (IS_ENABLED(CONFIG_LED_TRIGGER_PHY))\n'
        '\t\tphy_led_triggers_unregister(phydev);\n'
        '\treturn ret;\n'
        '}')
if old4 in c:
    c = c.replace(old4, new4, 1)
    changes += 1
    print('✅ [4/7] phy_probe 加 out_unreg_led 标签')
else:
    print('⚠️ [4/7] 未找到 out: 标签')

# --- 5) phy_attach_direct: 删除 LED 注册 ---
old5 = ('\tif (IS_ENABLED(CONFIG_LED_TRIGGER_PHY)) {\n'
        '\t\tret = phy_led_triggers_register(phydev);\n'
        '\t\tif (ret) {\n'
        '\t\t\tphy_detach(phydev);\n'
        '\t\t\treturn ret;\n'
        '\t\t}\n'
        '\t}\n')
if old5 in c:
    c = c.replace(old5, '', 1)
    changes += 1
    print('✅ [5/7] phy_attach_direct 删除 LED 注册')
else:
    print('⚠️ [5/7] 未找到 phy_attach_direct 锚点')

# --- 6) phy_detach: 删除 LED 注销 ---
old6 = ('\n\tif (IS_ENABLED(CONFIG_LED_TRIGGER_PHY))\n'
        '\t\tphy_led_triggers_unregister(phydev);\n')
if old6 in c:
    c = c.replace(old6, '', 1)
    changes += 1
    print('✅ [6/7] phy_detach 删除 LED 注销')
else:
    print('⚠️ [6/7] 未找到 phy_detach 锚点')

# --- 7) phy_remove: 添加 LED 注销 ---
old7 = ('\tmutex_lock(&phydev->lock);\n'
        '\tphydev->state = PHY_DOWN;\n'
        '\tmutex_unlock(&phydev->lock);\n\n'
        '\treturn 0;\n'
        '}')
new7 = ('\tmutex_lock(&phydev->lock);\n'
        '\tphydev->state = PHY_DOWN;\n'
        '\tmutex_unlock(&phydev->lock);\n\n'
        '\tif (IS_ENABLED(CONFIG_LED_TRIGGER_PHY))\n'
        '\t\tphy_led_triggers_unregister(phydev);\n\n'
        '\treturn 0;\n'
        '}')
if old7 in c:
    c = c.replace(old7, new7, 1)
    changes += 1
    print('✅ [7/7] phy_remove 添加 LED 注销')
else:
    print('⚠️ [7/7] 未找到 phy_remove 锚点')

if changes < 5:
    print(f'❌ 只完成 {changes}/{total} 处修改，内核版本可能不匹配')
    sys.exit(1)

with open(dev_c, 'w') as f:
    f.write(c)
print(f'✅ CVE-2026-23368 补丁已应用（{changes}/{total} 处）')
PYEOF