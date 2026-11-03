#!/usr/bin/env bash
# check_tablet.sh
# Diagnostic checker for 2-in-1 Tablet Mode & Hinge Detection

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BOLD='\033[1m'; NC='\033[0m'
ok()    { echo -e "  ${GREEN}✓${NC} $*"; }
fail()  { echo -e "  ${RED}✗${NC} $*"; }
warn()  { echo -e "  ${YELLOW}~${NC} $*"; }

echo -e "\n${BOLD}=== [2-in-1 Tablet Mode Diagnostics] ===${NC}"

# 1. Daemon service status
if systemctl is-active --quiet cros-tablet-mode.service 2>/dev/null; then
    ok "Service cros-tablet-mode.service is active and running"
else
    fail "Service cros-tablet-mode.service is INACTIVE"
fi

if systemctl is-enabled --quiet cros-tablet-mode.service 2>/dev/null; then
    ok "Service cros-tablet-mode.service is enabled on boot"
else
    warn "Service cros-tablet-mode.service is not enabled on boot"
fi

# 2. Hardware tablet switch
if ls /dev/input/by-path/*GOOG0006* 1>/dev/null 2>&1; then
    SW_PATH=$(ls /dev/input/by-path/*GOOG0006* | head -1)
    ok "Hardware ACPI switch detected: $SW_PATH"
else
    warn "Hardware switch /dev/input/by-path/*GOOG0006* not found (fallback to IIO active)"
fi

# 3. IIO Lid angle sensor
ANGLE_FOUND=false
for p in /sys/bus/iio/devices/iio:device*/in_angl_raw; do
    if [ -f "$p" ]; then
        VAL=$(cat "$p" 2>/dev/null || echo "N/A")
        ok "IIO hinge angle sensor reading: ${VAL}° ($p)"
        ANGLE_FOUND=true
        break
    fi
done
if [ "$ANGLE_FOUND" = false ]; then
    fail "IIO hinge angle sensor path not found"
fi

# 4. Libinput quirk for chassis volume buttons
if [ -f "/etc/libinput/local-overrides.quirks" ]; then
    if grep -q "ModelTabletModeNoSuspend=1" /etc/libinput/local-overrides.quirks 2>/dev/null; then
        ok "Libinput quirk ModelTabletModeNoSuspend=1 present (side volume keys preserved)"
    else
        warn "ModelTabletModeNoSuspend quirk not configured in /etc/libinput/local-overrides.quirks"
    fi
else
    fail "Libinput override quirks file missing (/etc/libinput/local-overrides.quirks)"
fi

# 5. Keyd profiles for laptop and tablet
if [ -f "/etc/keyd/profiles/cros-laptop.profile" ] && [ -f "/etc/keyd/profiles/cros-tablet.profile" ]; then
    ok "Keyd profiles present in /etc/keyd/profiles/ (laptop & tablet)"
else
    fail "Keyd profiles missing in /etc/keyd/profiles/"
fi

# 6. Touchpad inhibition node status
TOUCHPAD_INH=$(find /sys/class/input/input*/ -name inhibited 2>/dev/null | head -1 || true)
if [ -n "$TOUCHPAD_INH" ]; then
    INH_VAL=$(cat "$TOUCHPAD_INH" 2>/dev/null || echo "0")
    ok "Touchpad inhibition sysfs node active: state = $INH_VAL ($TOUCHPAD_INH)"
else
    warn "Touchpad inhibition sysfs node not located"
fi
