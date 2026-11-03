#!/usr/bin/env bash
# uninstall_keyboard.sh
# Removes keyd configuration and restores default kernel keyboard behavior

set -e

if [ "$EUID" -ne 0 ]; then
    echo "[!] Superuser privileges required."
    exec sudo bash "$0" "$@"
fi

echo "[*] Stopping and disabling keyd..."
systemctl disable --now keyd.service 2>/dev/null || true
rm -f /etc/keyd/cros.conf
rm -rf /etc/keyd/profiles

echo "[+] Keyboard configuration removed. Hardware restored to default behavior."
