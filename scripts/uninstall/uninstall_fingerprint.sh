#!/usr/bin/env bash
# uninstall_fingerprint.sh
# Removes fingerprint bridge service, unmasks upstream fprintd, and restores PAM

set -e

if [ "$EUID" -ne 0 ]; then
    echo "[!] Superuser privileges required."
    exec sudo bash "$0" "$@"
fi

echo "[*] Stopping and disabling cros-fprint-bridge.service..."
systemctl disable --now cros-fprint-bridge.service 2>/dev/null || true
rm -f /etc/systemd/system/cros-fprint-bridge.service
rm -f /usr/local/bin/cros-fprint-bridge.py

echo "[*] Unmasking upstream fprintd.service..."
systemctl unmask fprintd.service 2>/dev/null || true

echo "[*] Removing sleep hook for fingerprint..."
rm -f /lib/systemd/system-sleep/fingerprint-resume.sh

systemctl daemon-reload

echo "[+] Fingerprint bridge and custom sleep hooks removed."
