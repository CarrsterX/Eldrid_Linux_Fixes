#!/usr/bin/env bash
# uninstall_tablet.sh
# Uninstalls tablet mode daemon and restores default input hardware states

set -e

if [ "$EUID" -ne 0 ]; then
    echo "[!] Superuser privileges required."
    exec sudo bash "$0" "$@"
fi

echo "[*] Stopping and disabling cros-tablet-mode.service..."
systemctl disable --now cros-tablet-mode.service 2>/dev/null || true
rm -f /etc/systemd/system/cros-tablet-mode.service
rm -f /usr/local/bin/cros_tablet_daemon.py
rm -f /etc/libinput/local-overrides.quirks
rm -f /etc/cros_tablet_daemon.conf
udevadm control --reload 2>/dev/null || true
systemctl daemon-reload

for p in /sys/class/input/input*/inhibited; do
    [ -f "$p" ] && echo 0 > "$p" 2>/dev/null || true
done

echo "[+] Tablet mode daemon removed and default hardware states restored."
