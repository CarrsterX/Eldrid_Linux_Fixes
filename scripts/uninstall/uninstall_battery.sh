#!/usr/bin/env bash
# uninstall_battery.sh
# Removes custom TuneD profiles and udev autosuspend rules

set -e

if [ "$EUID" -ne 0 ]; then
    echo "[!] Superuser privileges required."
    exec sudo bash "$0" "$@"
fi

echo "[*] Removing TuneD profile overrides..."
rm -rf /etc/tuned/profiles/balanced-battery
rm -rf /etc/tuned/profiles/powersave

echo "[*] Removing udev battery powersave rule..."
rm -f /etc/udev/rules.d/90-eldrid-battery-powersave.rules
udevadm control --reload-rules 2>/dev/null || true

systemctl reload tuned.service 2>/dev/null || systemctl restart tuned.service 2>/dev/null || true

echo "[+] Battery profile overrides removed."
