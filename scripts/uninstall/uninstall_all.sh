#!/usr/bin/env bash
# uninstall_all.sh
# Uninstalls all Eldrid Linux Fixes modules

set -e

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ "$EUID" -ne 0 ]; then
    echo "[!] Superuser privileges required."
    exec sudo bash "$0" "$@"
fi

echo "=================================================================="
echo " UNINSTALLING ALL ELDRID LINUX FIXES                              "
echo "=================================================================="

bash "$DIR/uninstall_touchscreen.sh"
bash "$DIR/uninstall_keyboard.sh"
bash "$DIR/uninstall_tablet.sh"
bash "$DIR/uninstall_battery.sh"
bash "$DIR/uninstall_fingerprint.sh"

echo ""
echo "=================================================================="
echo " ALL MODULES UNINSTALLED SUCCESSFULLY                             "
echo "=================================================================="
