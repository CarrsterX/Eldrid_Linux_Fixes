#!/usr/bin/env bash
# uninstall_touchscreen.sh
# Uninstalls Goodix Touchscreen systemd service, sleep hooks, and ACPI overrides

set -e

if [ "$EUID" -ne 0 ]; then
    echo "[!] Superuser privileges required."
    exec sudo bash "$0" "$@"
fi

echo "[*] Removing Touchscreen persistent services and hooks..."

systemctl disable --now touchscreen-init.service 2>/dev/null || true
rm -f /etc/systemd/system/touchscreen-init.service
rm -f /usr/local/bin/fix-touchscreen.sh
rm -f /lib/systemd/system-sleep/touchscreen-resume.sh
rm -f /run/touchscreen-gpioset.pid
killall gpioset 2>/dev/null || true

systemctl daemon-reload

echo "[+] Touchscreen custom services and hooks removed."
