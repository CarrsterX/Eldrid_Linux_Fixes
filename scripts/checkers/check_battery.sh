#!/usr/bin/env bash
# check_battery.sh
# Diagnostic checker for Battery Life, S0ix Sleep Mode, and Power Profiles

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BOLD='\033[1m'; NC='\033[0m'
ok()    { echo -e "  ${GREEN}✓${NC} $*"; }
fail()  { echo -e "  ${RED}✗${NC} $*"; }
warn()  { echo -e "  ${YELLOW}~${NC} $*"; }

echo -e "\n${BOLD}=== [Battery & Power Management Diagnostics] ===${NC}"

# 1. Sleep mode (S0ix s2idle vs ACPI S3 deep)
if [ -f "/sys/power/mem_sleep" ]; then
    SLEEP_MODES=$(cat /sys/power/mem_sleep 2>/dev/null)
    if echo "$SLEEP_MODES" | grep -q "\[s2idle\]"; then
        ok "Active sleep mode is s2idle: $SLEEP_MODES (S0ix Modern Standby - Optimal for Eldrid)"
    elif echo "$SLEEP_MODES" | grep -q "\[deep\]"; then
        fail "Active sleep mode is deep (ACPI S3 - CAUSES ~1.9W BATTERY DRAIN ON ELDRID! Run optimize_battery.sh)"
    else
        warn "Current sleep mode setting: $SLEEP_MODES"
    fi
else
    fail "Path /sys/power/mem_sleep not accessible"
fi

# 2. GRUB configuration check
if [ -f "/etc/default/grub" ]; then
    if grep -q "mem_sleep_default=s2idle" /etc/default/grub 2>/dev/null; then
        ok "GRUB configuration has mem_sleep_default=s2idle (persistent across reboots)"
    elif grep -q "mem_sleep_default=deep" /etc/default/grub 2>/dev/null; then
        fail "GRUB configuration still specifies mem_sleep_default=deep"
    else
        warn "GRUB does not explicitly specify mem_sleep_default"
    fi
fi

# 3. TuneD profile status
ACTIVE_TUNED=$(tuned-adm active 2>/dev/null || echo "inactive")
if echo "$ACTIVE_TUNED" | grep -q -E "balanced-battery|powersave"; then
    ok "TuneD active profile: $ACTIVE_TUNED (Eldrid optimized)"
elif echo "$ACTIVE_TUNED" | grep -q "Current active profile:"; then
    ok "TuneD active profile: $ACTIVE_TUNED"
else
    warn "TuneD status: $ACTIVE_TUNED"
fi

# 4. tuned-ppd service (GNOME integration)
if systemctl is-active --quiet tuned-ppd.service 2>/dev/null; then
    ok "Service tuned-ppd.service is active (GNOME power slider integration functional)"
else
    warn "Service tuned-ppd.service is inactive"
fi

# 5. CPU Energy Performance Preference (EPP)
if [ -f "/sys/devices/system/cpu/cpu0/cpufreq/energy_performance_preference" ]; then
    EPP_VAL=$(cat /sys/devices/system/cpu/cpu0/cpufreq/energy_performance_preference 2>/dev/null)
    ok "Intel CPU0 EPP preference: $EPP_VAL"
else
    warn "CPU EPP sysfs interface not available"
fi

# 6. PCIe ASPM Policy
if [ -f "/sys/module/pcie_aspm/parameters/policy" ]; then
    ASPM_VAL=$(cat /sys/module/pcie_aspm/parameters/policy 2>/dev/null)
    if echo "$ASPM_VAL" | grep -q "\[powersupersave\]"; then
        ok "PCIe ASPM policy: $ASPM_VAL (Maximum PCIe bus power savings)"
    else
        warn "PCIe ASPM policy: $ASPM_VAL"
    fi
fi

# 7. ChromeOS EC charge end threshold
if [ -f "/sys/class/power_supply/BAT0/charge_control_end_threshold" ]; then
    THRESHOLD=$(cat /sys/class/power_supply/BAT0/charge_control_end_threshold 2>/dev/null)
    if [ "$THRESHOLD" -eq 80 ]; then
        ok "CrOS EC battery charge limit set to 80% (Hardware AC bypass enabled)"
    else
        warn "Battery charge limit is $THRESHOLD% (Default is 100%, recommended 80% for longevity)"
    fi
else
    warn "charge_control_end_threshold interface not exposed by battery driver"
fi

# 8. USB autosuspend udev rule
if [ -f "/etc/udev/rules.d/90-eldrid-battery-powersave.rules" ]; then
    ok "USB/PCIe autosuspend udev rule present: /etc/udev/rules.d/90-eldrid-battery-powersave.rules"
else
    warn "USB autosuspend udev rule not installed"
fi
