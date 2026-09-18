#!/bin/bash
# patch01.sh - CVE-2026-23368 PHY LED trigger AB-BA deadlock fix
# 自适应：先探测 register 在哪个函数，再决定是否打补丁
set -e

KERNEL_SRC="$1"
if [ -z "$KERNEL_SRC" ] || [ ! -d "$KERNEL_SRC" ]; then
    KERNEL_SRC=$(find build_dir -maxdepth 4 -type d -path "*/linux-rockchip_armv8/linux-*" 2>/dev/null | head -1)
    [ -z "$KERNEL_SRC" ] && KERNEL_SRC=$(find . -maxdepth 6 -type d -path "*/linux-rockchip_armv8/linux-*" 2>/dev/null | head -1)
fi
if [ -z "$KERNEL_SRC" ] || [ ! -d "$KERNEL_SRC" ]; then
    echo "❌ 未找到内核源码目录"
    exit 1
fi

echo "内核源码: $KERNEL_SRC"

python3 - "$KERNEL_SRC" << 'PYEOF'
import re, sys, os

src = sys.argv[1]
dev_c = os.path.join(src, 'drivers/net/phy/phy_device.c')

if not os.path.exists(dev_c):
    print(f'❌ 未找到 {dev_c}')
    sys.exit(1)

with open(dev_c) as f:
    c = f.read()

# 幂等检查
if 'CVE-2026-23368' in c:
    print('✅ 补丁已应用（检测到 CVE-2026-23368 标记），跳过')
    sys.exit(0)

# ---------- 1. 探测 register 在哪个函数 ----------
func_pat = re.compile(r'^static\s+(?:int|void|struct\s+\w+\s*\*?)\s+(\w+)\s*\(', re.MULTILINE)
funcs = sorted([(m.group(1), m.start()) for m in func_pat.finditer(c)], key=lambda x: x[1])

def enclosing(idx):
    name = '?'
    for n, s in funcs:
        if s <= idx:
            name = n
        else:
            break
    return name

reg_sites = []
for m in re.finditer(r'\bphy_led_triggers_register\s*\(', c):
    reg_sites.append((m.start(), enclosing(m.start())))

print('=== phy_led_triggers_register 调用位置 ===')
for idx, fn in reg_sites:
    line = c[:idx].count('\n') + 1
    print(f'  line {line}: 在 {fn}()')

if not reg_sites:
    print('⚠️ 未找到 phy_led_triggers_register 调用')
    print('   可能内核未启用 PHY LED trigger，跳过')
    sys.exit(0)

reg_in_probe = any(fn == 'phy_probe' for _, fn in reg_sites)
reg_in_attach = any(fn == 'phy_attach_direct' for _, fn in reg_sites)

if reg_in_probe:
    print('✅ register 已在 phy_probe()，CVE-2026-23368 已修复，无需处理')
    sys.exit(0)

if not reg_in_attach:
    print('⚠️ register 既不在 phy_probe 也不在 phy_attach_direct')
    print('   无法确定状态，跳过（不阻塞编译）')
    sys.exit(0)

# ---------- 2. 执行修复 ----------
print('▶ register 位于 phy_attach_direct()，执行 CVE-2026-23368 修复')

def find_func_body(text, name):
    """返回 (body_start, body_end)，body_end 是闭 '}' 的位置"""
    pat = re.compile(r'^static\s+\w+\s+' + re.escape(name) + r'\s*\([^)]*\)\s*\{', re.MULTILINE)
    m = pat.search(text)
    if not m:
        return None
    start = m.end()
    depth = 1
    i = start
    while i < len(text) and depth > 0:
        if text[i] == '{':
            depth += 1
        elif text[i] == '}':
            depth -= 1
        i += 1
    return (start, i - 1)

# --- 2.1 从 phy_attach_direct 删除 register 块 ---
a_body = find_func_body(c, 'phy_attach_direct')
if not a_body:
    print('❌ 未找到 phy_attach_direct')
    sys.exit(1)
a_start, a_end = a_body
a_code = c[a_start:a_end]

# 兼容 err/ret 两种变量名 + CONFIG_LED_TRIGGER_PHY / CONFIG_PHYLIB_LEDS
reg_pat = re.compile(
    r'\n\tif \(IS_ENABLED\(CONFIG_(?:LED_TRIGGER_PHY|PHYLIB_LEDS)\)\) \{\n'
    r'\t\t(?:err|ret) = phy_led_triggers_register\(phydev\);\n'
    r'\t\tif \((?:err|ret)\) \{\n'
    r'\t\t\tphy_detach\(phydev\);\n'
    r'\t\t\treturn (?:err|ret);\n'
    r'\t\t\}\n'
    r'\t\}\n'
)

m = reg_pat.search(a_code)
if not m:
    print('❌ phy_attach_direct 中未找到可识别的 register 块')
    idx = a_code.find('phy_led_triggers_register')
    if idx >= 0:
        print('=== 附近代码（500 字符）===')
        print(a_code[max(0, idx - 500):idx + 300])
    sys.exit(1)

c = c[:a_start] + a_code[:m.start()] + a_code[m.end():] + c[a_end:]
print('   ✓ phy_attach_direct: 已移除 register 块')

# --- 2.2 在 phy_probe 插入 register（用 err 变量，与 kernel 6.12 一致）---
p_body = find_func_body(c, 'phy_probe')
if not p_body:
    print('❌ 未找到 phy_probe')
    sys.exit(1)
p_start, p_end = p_body
p_code = c[p_start:p_end]

# 锚点：if (phydrv->flags & PHY_IS_INTERNAL) / phydev->is_internal = true;
anchor = re.compile(
    r'(\tif \(phydrv->flags & PHY_IS_INTERNAL\)\n'
    r'\t\tphydev->is_internal = true;\n)'
)
ma = anchor.search(p_code)
if not ma:
    print('❌ phy_probe 中未找到 "is_internal = true;" 锚点')
    print('=== phy_probe 前 1500 字符 ===')
    print(p_code[:1500])
    sys.exit(1)

insertion = (
    '\n\t/* CVE-2026-23368: register LED triggers during probe (RTNL not held) */\n'
    '\tif (IS_ENABLED(CONFIG_LED_TRIGGER_PHY)) {\n'
    '\t\terr = phy_led_triggers_register(phydev);\n'
    '\t\tif (err)\n'
    '\t\t\treturn err;\n'
    '\t}\n'
)
c = c[:p_start] + p_code[:ma.end()] + insertion + p_code[ma.end():] + c[p_end:]
print('   ✓ phy_probe: 已添加 register 调用')

# --- 2.3 从 phy_detach 删除 unregister ---
d_body = find_func_body(c, 'phy_detach')
if d_body:
    d_start, d_end = d_body
    d_code = c[d_start:d_end]
    unreg_pat = re.compile(
        r'\n\tif \(IS_ENABLED\(CONFIG_(?:LED_TRIGGER_PHY|PHYLIB_LEDS)\)\)\n'
        r'\t\tphy_led_triggers_unregister\(phydev\);\n'
    )
    new_d = unreg_pat.sub('', d_code, count=1)
    if new_d != d_code:
        c = c[:d_start] + new_d + c[d_end:]
        print('   ✓ phy_detach: 已移除 unregister')
    else:
        print('   ℹ️ phy_detach 中无 unregister（可能已移除）')
else:
    print('   ℹ️ 未找到 phy_detach')

# --- 2.4 phy_remove 保证有 unregister（幂等）---
r_body = find_func_body(c, 'phy_remove')
if r_body:
    r_start, r_end = r_body
    r_code = c[r_start:r_end]
    if 'phy_led_triggers_unregister' not in r_code:
        # 用 "phydev->state = PHY_DOWN;" 作为锚点插入
        anchor2 = re.compile(r'(\tphydev->state = PHY_DOWN;\n)')
        ma2 = anchor2.search(r_code)
        if ma2:
            insertion2 = (
                '\n\tif (IS_ENABLED(CONFIG_LED_TRIGGER_PHY))\n'
                '\t\tphy_led_triggers_unregister(phydev);\n'
            )
            c = c[:r_start] + r_code[:ma2.start()] + insertion2 + r_code[ma2.start():] + c[r_end:]
            print('   ✓ phy_remove: 已添加 unregister')
        else:
            print('   ⚠️ phy_remove 中未找到插入锚点（跳过）')
    else:
        print('   ℹ️ phy_remove 已有 unregister（无需操作）')
else:
    print('   ℹ️ 未找到 phy_remove')

# --- 3. 写回 ---
with open(dev_c, 'w') as f:
    f.write(c)

print('✅ CVE-2026-23368 修复已应用')
PYEOF