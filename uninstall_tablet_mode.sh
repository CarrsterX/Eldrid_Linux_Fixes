#!/usr/bin/env bash
# uninstall_tablet_mode.sh
# Uninstalls tablet mode daemon and restores default input hardware states

set -e

if [ "$EUID" -ne 0 ]; then
    echo "[!] Superuser privileges required."
    echo "[*] Elevating: sudo bash $0 $@"
    exec sudo bash "$0" "$@"
fi

echo "[*] Stopping and disabling cros-tablet-mode.service..."
systemctl disable --now cros-tablet-mode.service 2>/dev/null || true
rm -f /etc/systemd/system/cros-tablet-mode.service
rm -f /usr/local/bin/cros_tablet_daemon.py
rm -f /etc/udev/rules.d/99-keyd-internal.rules
rm -f /etc/libinput/local-overrides.quirks
udevadm control --reload 2>/dev/null || true
systemctl daemon-reload

for p in /sys/class/input/input*/inhibited; do
    [ -f "$p" ] && echo 0 > "$p" 2>/dev/null || true
done

echo "[+] Tablet mode service uninstalled. Hardware states restored."
