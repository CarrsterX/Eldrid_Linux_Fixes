#!/usr/bin/env bash
# check_touchscreen.sh
# Diagnostic checker for Goodix Touchscreen Digitizer (GDIX0000)

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BOLD='\033[1m'; NC='\033[0m'
ok()    { echo -e "  ${GREEN}✓${NC} $*"; }
fail()  { echo -e "  ${RED}✗${NC} $*"; }
warn()  { echo -e "  ${YELLOW}~${NC} $*"; }

echo -e "\n${BOLD}=== [Touchscreen Digitizer Diagnostics] ===${NC}"

# 1. Driver binding
if [ -d "/sys/bus/i2c/drivers/i2c_hid_acpi/i2c-GDIX0000:00" ]; then
    ok "Driver i2c_hid_acpi bound to i2c-GDIX0000:00"
else
    fail "Touchscreen device i2c-GDIX0000:00 NOT bound to i2c_hid_acpi"
fi

# 2. Kernel input device node
TOUCH_INPUT=$(grep -l "GDIX0000" /sys/class/input/input*/name 2>/dev/null | head -1 || true)
if [ -n "$TOUCH_INPUT" ]; then
    INPUT_NAME=$(cat "$TOUCH_INPUT" 2>/dev/null)
    ok "Input node detected: $INPUT_NAME ($(dirname "$TOUCH_INPUT"))"
else
    warn "Direct input node name match not found (may use generic HID name)"
fi

# 3. Post-resume sleep hook
if [ -x "/lib/systemd/system-sleep/touchscreen-resume.sh" ]; then
    ok "Sleep resume hook installed and executable: /lib/systemd/system-sleep/touchscreen-resume.sh"
else
    fail "Sleep resume hook missing or not executable (/lib/systemd/system-sleep/touchscreen-resume.sh)"
fi

# 4. Resume log verification
if [ -f "/var/log/touchscreen-init.log" ]; then
    LAST_LOG=$(tail -n 1 /var/log/touchscreen-init.log 2>/dev/null)
    ok "Touchscreen log exists. Last entry: $LAST_LOG"
else
    warn "Log file /var/log/touchscreen-init.log not created yet"
fi

# 5. Dmesg driver status
if dmesg 2>/dev/null | grep -i -E "gdix|goodix" | tail -n 1 | grep -q -i "error"; then
    fail "Recent dmesg reports Goodix error: $(dmesg | grep -i -E "gdix|goodix" | tail -n 1)"
else
    ok "No Goodix errors reported in recent dmesg buffer"
fi

