#!/usr/bin/env bash
# install_tablet_mode.sh
# Complete tablet mode detection & key management installer for HP Chromebook x360 14c (Eldrid)
#
# Features:
# 1. Real-time ACPI hardware switch monitoring (GOOG0006 / evdev event) with IIO lid angle fallback.
# 2. Dynamic keyd profile switching (cros-laptop.profile <-> cros-tablet.profile).
#    - Mutes 267 physical keys in tablet mode (Tab, Backspace, ChromeOS special keys, typing keys).
#    - Keeps physical chassis volume rocker (+/-) fully operational.
# 3. Synchronized keyboard backlight: Turns off in tablet mode, restores brightness in laptop mode.
# 4. Hardware touchpad inhibition while folded.
# 5. Smart backlight auto-timeout (ChromeOS-style idle power saving, wake on key/touchpad).

set -e

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ "$EUID" -ne 0 ]; then
    echo "[!] Superuser privileges required."
    echo "[*] Elevating: sudo bash $0 $@"
    exec sudo bash "$0" "$@"
fi

echo "=================================================================="
echo " TABLET MODE DAEMON & INPUT INTEGRATION (HP CHROMEBOOK ELDRID) "
echo "=================================================================="

# 1. Install daemon to /usr/local/bin
echo "[*] Installing daemon to /usr/local/bin/cros_tablet_daemon.py..."
cp -f "$DIR/cros_tablet_daemon.py" /usr/local/bin/cros_tablet_daemon.py
chmod 755 /usr/local/bin/cros_tablet_daemon.py

# 2. Configure keyd profiles
echo "[*] Setting up keyd profiles in /etc/keyd/profiles/..."
mkdir -p /etc/keyd/profiles

cp -f "$DIR/cros-laptop.profile" /etc/keyd/profiles/cros-laptop.profile
cp -f "$DIR/cros-tablet.profile" /etc/keyd/profiles/cros-tablet.profile
chmod 644 /etc/keyd/profiles/cros-laptop.profile /etc/keyd/profiles/cros-tablet.profile

# Set initial active config to laptop profile if not configured
if [ ! -f /etc/keyd/cros.conf ]; then
    cp -f /etc/keyd/profiles/cros-laptop.profile /etc/keyd/cros.conf
    chmod 644 /etc/keyd/cros.conf
fi

# 3. Configure libinput quirks (ModelTabletModeNoSuspend)
echo "[*] Configuring /etc/libinput/local-overrides.quirks..."
mkdir -p /etc/libinput
cat << 'QUIRK' > /etc/libinput/local-overrides.quirks
# Quirk for HP Chromebook x360 convertible (Eldrid):
# Informs libinput not to suspend keyboard events so the side chassis
# volume keys pass through cleanly in tablet mode. Typing keys are muted
# by cros_tablet_daemon via keyd profile switching.
[HP Chromebook x360 Eldrid Internal Keyboard]
MatchName=AT Translated Set 2 keyboard
ModelTabletModeNoSuspend=1

[HP Chromebook x360 Eldrid Keyd Virtual Keyboard]
MatchName=keyd virtual keyboard
ModelTabletModeNoSuspend=1
QUIRK

chmod 644 /etc/libinput/local-overrides.quirks

# Remove legacy/conflicting udev rules
rm -f /etc/udev/rules.d/99-keyd-internal.rules

# 4. Clear any stale input inhibition
for p in /sys/class/input/input*/name; do
    if [ -f "$p" ]; then
        n=$(cat "$p" 2>/dev/null || true)
        if echo "$n" | grep -qE "AT Translated|Touchpad|keyd"; then
            inh="$(dirname "$p")/inhibited"
            if [ -f "$inh" ]; then
                echo 0 > "$inh" 2>/dev/null || true
            fi
        fi
    fi
done

# 4b. Configure battery-saving keyboard backlight idle timeout
if [ ! -f /etc/cros_tablet_daemon.conf ]; then
    echo "[*] Creating /etc/cros_tablet_daemon.conf (Default 30s timeout)..."
    cat << 'CONF' > /etc/cros_tablet_daemon.conf
# Hardware daemon configuration for HP Chromebook x360 14c (Eldrid)
# Idle timeout without keyboard or touchpad interaction before turning off backlight LEDs (in seconds).
# Default: 30 seconds (ChromeOS style). Set to 0 to disable auto-timeout.
KBD_IDLE_TIMEOUT=30
CONF
    chmod 644 /etc/cros_tablet_daemon.conf
fi

# 5. Deploy systemd service unit
echo "[*] Deploying /etc/systemd/system/cros-tablet-mode.service..."
cat << 'UNIT' > /etc/systemd/system/cros-tablet-mode.service
[Unit]
Description=ChromeOS Eldrid Tablet Mode Daemon (Hinge, Touchpad, Keyboard & LED Integration)
After=multi-user.target keyd.service

[Service]
Type=simple
Environment=PYTHONUNBUFFERED=1
ExecStart=/usr/bin/python3 /usr/local/bin/cros_tablet_daemon.py
Restart=always
RestartSec=2s

[Install]
WantedBy=multi-user.target
UNIT

chmod 644 /etc/systemd/system/cros-tablet-mode.service

# 6. Reload udev and restart services
echo "[*] Reloading udev rules..."
udevadm control --reload 2>/dev/null || true
udevadm trigger 2>/dev/null || true

echo "[*] Reloading systemd and restarting services..."
systemctl daemon-reload
systemctl restart keyd.service 2>/dev/null || true
systemctl enable --now cros-tablet-mode.service
systemctl restart cros-tablet-mode.service

echo ""
echo "=================================================================="
echo " TABLET MODE SERVICE SUCCESSFULLY DEPLOYED! "
echo "=================================================================="
echo "Service Status:"
systemctl status cros-tablet-mode.service --no-pager || true
echo ""
echo "KEY HIGHLIGHTS:"
echo "  1. Side Volume Buttons: Preserved and functional in tablet mode."
echo "  2. Keyboard Silencing: Tab, Backspace, top-row and typing keys muted."
echo "  3. Keyboard Backlight: Turned off in tablet mode, restored in laptop mode."
echo "  4. Touchpad: Inhibited via hardware sysfs in tablet orientation."
echo "=================================================================="
