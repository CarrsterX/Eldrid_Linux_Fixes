#!/usr/bin/env bash
# optimize_battery.sh
# Power and battery optimizations for HP Chromebook x360 14c (Eldrid / Google Volteer)
# Overrides TuneD profiles in /etc/tuned/profiles/ to preserve GNOME power-profiles-daemon compatibility.
# Configures kernel sysctl, udev autosuspend rules, and GRUB parameters (S0ix s2idle, PCIe ASPM).

set -e

if [ "$EUID" -ne 0 ]; then
    echo "[!] Superuser privileges required."
    exec sudo bash "$0" "$@"
fi

echo "=================================================================="
echo " BATTERY OPTIMIZATION SUITE - HP CHROMEBOOK x360 14c (ELDRID) "
echo "=================================================================="
echo ""

# Verify tuned-ppd service health before applying overrides
if ! systemctl is-active --quiet tuned-ppd.service; then
    echo "[*] tuned-ppd service inactive. Restoring default profile configuration..."
    if grep -q "eldrid" /etc/tuned/ppd.conf 2>/dev/null; then
        cat > /etc/tuned/ppd.conf << 'PPD'
[main]
default=balanced
battery_detection=true
sysfs_acpi_monitor=true

[profiles]
power-saver=powersave
balanced=balanced
performance=throughput-performance

[battery]
balanced=balanced-battery
PPD
        chmod 644 /etc/tuned/ppd.conf
        echo "      -> ppd.conf restored to defaults"
    fi
    systemctl restart tuned-ppd.service
    sleep 2
fi

# Step 1: Deploy optimized TuneD profiles to /etc/tuned/profiles/
echo "[1/3] Deploying optimized TuneD profiles to /etc/tuned/profiles/..."
echo "      (Preserves GNOME standard profile names: balanced, powersave, etc.)"
echo ""

# --- balanced-battery: GNOME Balanced profile when running on battery ---
mkdir -p /etc/tuned/profiles/balanced-battery
cat > /etc/tuned/profiles/balanced-battery/tuned.conf << 'TUNED'
# Profile: balanced-battery override (HP Chromebook x360 14c Eldrid)
[main]
summary=Balanced (Eldrid) - Balanced performance and battery saving for HP Chromebook x360 14c
include=balanced

[cpu]
# Tiger Lake i3-1115G4: balance_power preference
energy_performance_preference=balance_power
boost=1

[video]
panel_power_savings=1

[audio]
timeout=10

[sysctl]
# Reduce dirty page writeback wakeups on battery
vm.dirty_writeback_centisecs=6000
kernel.nmi_watchdog=0
TUNED
echo "      -> balanced-battery profile deployed"

# --- powersave: GNOME Power Saver profile ---
mkdir -p /etc/tuned/profiles/powersave
cat > /etc/tuned/profiles/powersave/tuned.conf << 'TUNED'
# Profile: powersave override (HP Chromebook x360 14c Eldrid)
[main]
summary=Power Saver (Eldrid) - Maximum battery life for HP Chromebook x360 14c
include=powersave

[cpu]
energy_performance_preference=power
boost=0

[acpi]
platform_profile=low-power|quiet

[eeepc_she]

[vm]

[audio]
timeout=10

[video]
radeon_powersave=dpm-battery, auto
panel_power_savings=3

[scsi_host]
alpm=min_power

[sysctl]
vm.dirty_writeback_centisecs=6000
kernel.nmi_watchdog=0
TUNED
echo "      -> powersave profile deployed"

# Step 2: Global kernel and udev power optimizations
echo ""
echo "[2/3] Configuring udev autosuspend rules and GRUB parameters..."

# Deploy udev autosuspend rule for USB and PCI devices
mkdir -p /etc/udev/rules.d
cat > /etc/udev/rules.d/90-eldrid-battery-powersave.rules << 'UDEV'
# Global USB and PCIe autosuspend rules
ACTION=="add", SUBSYSTEM=="usb", TEST=="power/control", ATTR{power/control}="auto"
ACTION=="add", SUBSYSTEM=="usb", TEST=="power/autosuspend_delay_ms", ATTR{power/autosuspend_delay_ms}="2000"
ACTION=="add", SUBSYSTEM=="pci", TEST=="power/control", ATTR{power/control}="auto"
UDEV
echo "      -> udev rule written: /etc/udev/rules.d/90-eldrid-battery-powersave.rules"

# Apply USB autosuspend to existing devices
USB_COUNT=0
for U in /sys/bus/usb/devices/*/power/control; do
    [ -f "$U" ] && echo "auto" > "$U" 2>/dev/null && USB_COUNT=$((USB_COUNT+1)) || true
done
echo "      -> USB autosuspend enabled on $USB_COUNT devices"

# GRUB kernel parameters: PCIe ASPM, NMI watchdog, S0ix s2idle
GRUB_CONF=/etc/default/grub
PARAMS_ADD=""
grep -q "pcie_aspm.policy=powersupersave" "$GRUB_CONF" 2>/dev/null || PARAMS_ADD="$PARAMS_ADD pcie_aspm.policy=powersupersave"
grep -q "nmi_watchdog=0" "$GRUB_CONF" 2>/dev/null              || PARAMS_ADD="$PARAMS_ADD nmi_watchdog=0"

# S0ix Modern Standby (s2idle): Volteer lacks ACPI S3 sequencers (~1.9W leak). Native s2idle reduces draw to ~0.4W
if grep -q "mem_sleep_default=deep" "$GRUB_CONF" 2>/dev/null; then
    sed -i "s/mem_sleep_default=deep/mem_sleep_default=s2idle/g" "$GRUB_CONF"
    echo "      -> GRUB: migrated mem_sleep_default from deep to s2idle (native S0ix)"
elif ! grep -q "mem_sleep_default" "$GRUB_CONF" 2>/dev/null; then
    PARAMS_ADD="$PARAMS_ADD mem_sleep_default=s2idle"
fi

if [ -n "$PARAMS_ADD" ] && [ -f "$GRUB_CONF" ]; then
    TRIM=$(echo "$PARAMS_ADD" | xargs)
    sed -i "s|GRUB_CMDLINE_LINUX=\"\(.*\)\"|GRUB_CMDLINE_LINUX=\"\1 $TRIM\"|" "$GRUB_CONF"
    grub2-mkconfig -o /boot/efi/EFI/fedora/grub.cfg 2>/dev/null || \
    grub2-mkconfig -o /boot/grub2/grub.cfg 2>/dev/null && \
    echo "      -> GRUB updated with:$PARAMS_ADD (effective on next boot)" || \
    echo "      [!] GRUB: run 'grub2-mkconfig' manually"
else
    echo "      -> GRUB: parameters already present"
fi

# Apply s2idle to current session if supported
if [ -f /sys/power/mem_sleep ] && grep -q "s2idle" /sys/power/mem_sleep 2>/dev/null; then
    echo s2idle > /sys/power/mem_sleep 2>/dev/null || true
    echo "      -> Live sleep mode configured to s2idle"
fi

# Step 3: Reload TuneD daemon
echo ""
echo "[3/3] Reloading TuneD daemon..."

udevadm control --reload-rules 2>/dev/null || true
systemctl reload tuned.service 2>/dev/null || systemctl restart tuned.service 2>/dev/null || true
sleep 1

echo ""
echo "=================================================================="
echo " CONFIGURATION COMPLETE"
echo "=================================================================="
echo ""
echo "ACTIVE STATUS:"
tuned-adm active 2>/dev/null || true
systemctl is-active --quiet tuned-ppd.service && echo "tuned-ppd: ACTIVE (GNOME integration functional)" || echo "tuned-ppd: INACTIVE"
echo ""
echo "GLOBAL PM SETTINGS:"
echo "  USB autosuspend: 2s (udev)"
echo "  PCIe ASPM: powersupersave (GRUB)"
echo "  Sleep Mode: s2idle S0ix (GRUB & live)"
echo ""
echo "BATTERY LONGEVITY (Optional):"
echo "  Limit charge to 80%:"
echo "  echo 80 | sudo tee /sys/class/power_supply/BAT0/charge_control_end_threshold"
echo "=================================================================="
