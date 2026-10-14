#!/usr/bin/env bash
# install_tablet_mode.sh
# Tablet mode detection daemon installer for HP Chromebook x360 14c (Eldrid) (ChromeOS 2-in-1)

set -e

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ "$EUID" -ne 0 ]; then
    echo "[!] Superuser privileges required."
    echo "[*] Elevating: sudo bash $0 $@"
    exec sudo bash "$0" "$@"
fi

echo "=================================================================="
echo " TABLET MODE DAEMON INSTALLER (CHROMEBOOK ELDRID) "
echo "=================================================================="

# 1. Install daemon to /usr/local/bin
echo "[*] Installing daemon to /usr/local/bin/cros_tablet_daemon.py..."
cp -f "$DIR/cros_tablet_daemon.py" /usr/local/bin/cros_tablet_daemon.py
chmod 755 /usr/local/bin/cros_tablet_daemon.py

# 2. Configure libinput and udev integration rules
echo "[*] Configuring internal keyboard integration quirks for libinput and udev..."
mkdir -p /etc/udev/rules.d /etc/libinput

cat << 'UDEV' > /etc/udev/rules.d/99-keyd-internal.rules
ACTION=="add|change", KERNEL=="event*", ATTRS{name}=="keyd virtual keyboard", ENV{ID_INPUT_KEYBOARD_INTEGRATION}="internal", ENV{ID_INTEGRATION}="internal"
UDEV
chmod 644 /etc/udev/rules.d/99-keyd-internal.rules

cat << 'QUIRK' > /etc/libinput/local-overrides.quirks
[Keyd Virtual Keyboard]
MatchName=keyd virtual keyboard
MatchUdevType=keyboard
AttrKeyboardIntegration=internal
QUIRK
chmod 644 /etc/libinput/local-overrides.quirks

udevadm control --reload 2>/dev/null || true
udevadm trigger 2>/dev/null || true

# 3. Ensure physical keyboard inhibit attribute is cleared
for p in /sys/class/input/input*/name; do
    if [ -f "$p" ] && grep -q "AT Translated" "$p" 2>/dev/null; then
        inhibit="$(dirname "$p")/inhibited"
        if [ -f "$inhibit" ]; then
            echo 0 > "$inhibit"
        fi
    fi
done

# 4. Deploy and start systemd service
echo "[*] Deploying systemd unit /etc/systemd/system/cros-tablet-mode.service..."
cat << 'UNIT' > /etc/systemd/system/cros-tablet-mode.service
[Unit]
Description=ChromeOS Eldrid Tablet Mode Daemon (Hinge, Touchpad, Keyboard & LED Integration)
After=multi-user.target

[Service]
ExecStart=/usr/bin/python3 /usr/local/bin/cros_tablet_daemon.py
Restart=always
RestartSec=2s

[Install]
WantedBy=multi-user.target
UNIT

chmod 644 /etc/systemd/system/cros-tablet-mode.service

echo "[*] Reloading systemd and starting service..."
systemctl daemon-reload
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
echo "  1. Shake / Movement Filter: Requires sustained angle (>= 215 deg for > 1.0s)"
echo "     and discards ChromeOS EC 500 (LID_ANGLE_UNRELIABLE) to avoid false positives."
echo "  2. Side Volume Buttons: Preserved and functional at all times."
echo "  3. Typing & Touchpad: Cleanly disabled in tablet orientation via libinput/sysfs."
echo "  4. Keyboard Backlight: Turned off in tablet mode and restored in laptop mode."
echo "=================================================================="
