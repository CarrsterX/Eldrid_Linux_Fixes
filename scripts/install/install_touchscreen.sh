#!/usr/bin/env bash
# Helper installer wrapper requiring superuser privileges

set -e

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ "$EUID" -ne 0 ]; then
    echo "[!] Superuser privileges required."
    echo "[*] Elevating: sudo python3 $DIR/apply_touchscreen_fix.py"
    exec sudo python3 "$DIR/apply_touchscreen_fix.py"
else
    exec python3 "$DIR/apply_touchscreen_fix.py"
fi
