#!/bin/bash
# patch01.sh - CVE-2026-23368 PHY LED trigger AB-BA deadlock fix
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
import sys, os, re

src = sys.argv[1]
dev_c = os.path.join(src, 'drivers/net/phy/phy_device.c')

if not os.path.exists(dev_c):
    print(f'❌ 未找到 {dev_c}')
    sys.exit(1)

with open(dev_c, 'r') as f:
    c = f.read()

# 幂等检查：已经应用过就跳过
if 'CVE-2026-23368' in c:
    print('✅ 补丁已应用（检测到标记），跳过')
    sys.exit(0)

if 'phy_led_triggers_register' not in c:
    print('⚠️ phy_device.c 中未找到 phy_led_triggers_register')
    print('   可能内核未开启 CONFIG_LED_TRIGGER_PHY，跳过')
    sys.exit(0)

changes = 0
total = 5
matched = []

# ==================== [1/5] phy_probe: 插入 LED 注册 ====================
# 正则：匹配 "is_internal = true;" 到 "mutex_lock(&phydev->lock);" 之间
pattern1 = re.compile(
    r'(\tif \(phydrv->flags & PHY_IS_INTERNAL\)\n'
    r'\t\tphydev->is_internal = true;\n)'
    r'(\s*)'
    r'(\tmutex_lock\(&phydev->lock\);)'
)

m = pattern1.search(c)
if m:
    insertion = (
        '\n\t/* CVE-2026-23368: register LED triggers during probe */\n'
        '\tif (IS_ENABLED(CONFIG_LED_TRIGGER_PHY)) {\n'
        '\t\terr = phy_led_triggers_register(phydev);\n'
        '\t\tif (err)\n'
        '\t\t\treturn err;\n'
        '\t}\n'
    )
    c = c[:m.end(1)] + insertion + m.group(2) + m.group(3) + c[m.end():]
    changes += 1
    matched.append('1')
    print('✅ [1/5] phy_probe 插入 LED 注册')
else:
    print('⚠️ [1/5] 未匹配')

# ==================== [2/5] phy_probe: out: 加 LED 注销 ====================
# 正则：out: -> mutex_unlock -> return err; -> }
pattern2 = re.compile(
    r'(out:\s*\n'
    r'\tmutex_unlock\(&phydev->lock\);\s*\n)'
    r'(\s*)'
    r'(\treturn err;\s*\n\})',
    re.MULTILINE
)

m = pattern2.search(c)
if m:
    insertion = (
        '\n\tif (IS_ENABLED(CONFIG_LED_TRIGGER_PHY))\n'
        '\t\tphy_led_triggers_unregister(phydev);\n'
    )
    c = c[:m.end(1)] + insertion + m.group(2) + m.group(3) + c[m.end():]
    changes += 1
    matched.append('2')
    print('✅ [2/5] phy_probe out: 加 LED 注销')
else:
    print('⚠️ [2/5] 未匹配')

# ==================== [3/5] phy_attach_direct: 删除 LED 注册 ====================
# 正则匹配 err/ret 两种变量名
pattern3 = re.compile(
    r'\n\tif \(IS_ENABLED\(CONFIG_LED_TRIGGER_PHY\)\) \{\n'
    r'\t\t(?:err|ret) = phy_led_triggers_register\(phydev\);\n'
    r'\t\tif \((?:err|ret)\) \{\n'
    r'\t\t\tphy_detach\(phydev\);\n'
    r'\t\t\treturn (?:err|ret);\n'
    r'\t\t\}\n'
    r'\t\}\n'
)

if pattern3.search(c):
    c = pattern3.sub('', c, count=1)
    changes += 1
    matched.append('3')
    print('✅ [3/5] phy_attach_direct 删除 LED 注册')
else:
    print('⚠️ [3/5] 未匹配')

# ==================== [4/5] phy_detach: 删除 LED 注销 ====================
pattern4 = re.compile(
    r'\n\tif \(IS_ENABLED\(CONFIG_LED_TRIGGER_PHY\)\)\n'
    r'\t\tphy_led_triggers_unregister\(phydev\);\n'
)

if pattern4.search(c):
    c = pattern4.sub('', c, count=1)
    changes += 1
    matched.append('4')
    print('✅ [4/5] phy_detach 删除 LED 注销')
else:
    print('⚠️ [4/5] 未匹配')

# ==================== [5/5] phy_remove: 加 LED 注销 ====================
# 用大括号配对找到 phy_remove 函数体
m_remove = re.search(r'static int phy_remove\(struct device \*dev\)\s*\{', c)
if m_remove:
    # 从函数体开始扫描大括号
    body_start = m_remove.end()
    depth = 1
    i = body_start
    while i < len(c) and depth > 0:
        if c[i] == '{':
            depth += 1
        elif c[i] == '}':
            depth -= 1
        i += 1
    func_end = i - 1  # 指向匹配的 }
    func_body = c[body_start:func_end]

    # 找最后一个 "\treturn 0;"
    idx = func_body.rfind('\treturn 0;')
    if idx >= 0:
        insertion = (
            '\n\tif (IS_ENABLED(CONFIG_LED_TRIGGER_PHY))\n'
            '\t\tphy_led_triggers_unregister(phydev);\n'
        )
        # 找到 return 0; 前面的换行位置
        pre = func_body[:idx].rstrip()
        new_body = pre + insertion + '\n\n\treturn 0;' + func_body[idx + len('\treturn 0;'):]
        c = c[:body_start] + new_body + c[func_end:]
        changes += 1
        matched.append('5')
        print('✅ [5/5] phy_remove 加 LED 注销')
    else:
        print('⚠️ [5/5] phy_remove 里未找到 return 0;')
else:
    print('⚠️ [5/5] 未找到 phy_remove 函数')

# ==================== 结果处理 ====================
if changes >= 3:
    with open(dev_c, 'w') as f:
        f.write(c)
    print(f'✅ CVE-2026-23368 补丁已应用（{changes}/{total} 处）')
else:
    print(f'❌ 只完成 {changes}/{total} 处修改，内核版本可能不匹配')
    print('')
    print('========== 诊断信息 ==========')
    print('=== phy_probe 函数头 1000 字符 ===')
    m = re.search(r'(static int phy_probe\(struct device \*dev\)\s*\{)', c)
    if m:
        print(c[m.start():m.start()+1000])
    print('')
    print('=== phy_remove 函数头 500 字符 ===')
    m = re.search(r'(static int phy_remove\(struct device \*dev\)\s*\{)', c)
    if m:
        print(c[m.start():m.start()+500])
    print('')
    print('=== phy_led_triggers 相关行 ===')
    for i, line in enumerate(c.split('\n')):
        if 'phy_led_triggers' in line:
            print(f'{i}: {line}')
    print('==============================')
    sys.exit(1)
PYEOF