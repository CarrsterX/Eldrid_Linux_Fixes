#!/usr/bin/env bash
# check_keyboard.sh
# Diagnostic checker for Keyboard Remapping & Fn-Lock (keyd)

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BOLD='\033[1m'; NC='\033[0m'
ok()    { echo -e "  ${GREEN}✓${NC} $*"; }
fail()  { echo -e "  ${RED}✗${NC} $*"; }
warn()  { echo -e "  ${YELLOW}~${NC} $*"; }

echo -e "\n${BOLD}=== [Keyboard Remapping (Keyd) Diagnostics] ===${NC}"

# 1. keyd service status
if systemctl is-active --quiet keyd.service 2>/dev/null; then
    ok "Service keyd.service is active and running"
else
    fail "Service keyd.service is INACTIVE or failed"
fi

if systemctl is-enabled --quiet keyd.service 2>/dev/null; then
    ok "Service keyd.service is enabled on boot"
else
    warn "Service keyd.service is not enabled on boot"
fi

# 2. Configuration file
if [ -f "/etc/keyd/cros.conf" ]; then
    ok "Configuration /etc/keyd/cros.conf exists"
    
    if grep -q "function_keys" /etc/keyd/cros.conf 2>/dev/null; then
        ok "Dynamic Fn-Lock layer [function_keys] defined"
    else
        warn "Fn-Lock layer not found in /etc/keyd/cros.conf"
    fi

    if grep -q "f5 = leftmeta" /etc/keyd/cros.conf 2>/dev/null; then
        ok "Overview key (F5) mapped to Super (leftmeta)"
    else
        warn "F5 -> Super mapping not detected in default layer"
    fi
else
    fail "Configuration file /etc/keyd/cros.conf missing"
fi

# 3. Virtual input device
if grep -q "keyd virtual keyboard" /proc/bus/input/devices 2>/dev/null; then
    ok "Virtual keyboard node 'keyd virtual keyboard' detected in /proc/bus/input/devices"
else
    warn "Virtual keyboard device not found in /proc/bus/input/devices"
fi

# 4. Keyboard backlight sysfs interface
if [ -f "/sys/class/leds/chromeos::kbd_backlight/brightness" ]; then
    CURR_BRIGHT=$(cat /sys/class/leds/chromeos::kbd_backlight/brightness 2>/dev/null)
    MAX_BRIGHT=$(cat /sys/class/leds/chromeos::kbd_backlight/max_brightness 2>/dev/null || echo 100)
    ok "Keyboard backlight sysfs available: $CURR_BRIGHT / $MAX_BRIGHT"
else
    warn "Keyboard backlight sysfs node not found"
fi

