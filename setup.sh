#!/usr/bin/env bash
# setup.sh
# Unified Master Installer for HP Chromebook x360 14c (Eldrid / Google Volteer)
# Manages Touchscreen (Goodix), Keyboard (Keyd), and 2-in-1 Tablet Mode.

set -e

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ "$EUID" -ne 0 ]; then
    echo "[!] Superuser privileges required. Re-launching with sudo..."
    exec sudo bash "$0" "$@"
fi

show_banner() {
    clear 2>/dev/null || true
    echo "=================================================================="
    echo "       HP CHROMEBOOK x360 14c (ELDRID) - LINUX HARDWARE SUITE     "
    echo "=================================================================="
    echo "  1) Install ALL (Touchscreen + Keyboard + Tablet Mode) [Recommended]"
    echo "  2) Install Touchscreen Fix (Goodix I2C Digitizer)"
    echo "  3) Install Keyboard Fix (ChromeOS Top Row + F5 Overview + Lock Key)"
    echo "  4) Install Tablet Mode Daemon (Hinge, Backlight, Key & Volume Mgmt)"
    echo "  5) Live System Diagnostics"
    echo "  6) Exit"
    echo "=================================================================="
}

install_touchscreen() {
    echo ""
    echo ">>> [1/3] INSTALLING TOUCHSCREEN FIX..."
    bash "$DIR/install_fix.sh"
}

install_keyboard() {
    echo ""
    echo ">>> [2/3] INSTALLING KEYBOARD FIX..."
    bash "$DIR/install_keyboard_fix.sh"
}

install_tablet() {
    echo ""
    echo ">>> [3/3] INSTALLING TABLET MODE DAEMON..."
    bash "$DIR/install_tablet_mode.sh"
}

run_diagnostics() {
    echo ""
    echo "=================================================================="
    echo " LIVE HARDWARE DIAGNOSTICS "
    echo "=================================================================="
    echo -n "1. Touchscreen I2C Driver: "
    if [ -d "/sys/bus/i2c/drivers/i2c_hid_acpi/i2c-GDIX0000:00" ]; then
        echo "[OK] Bound and active (i2c-GDIX0000:00)"
    else
        echo "[!] Unbound. Run option 2."
    fi

    echo -n "2. Keyd Keyboard Service: "
    if systemctl is-active --quiet keyd.service; then
        echo "[OK] Active and running"
    else
        echo "[!] Inactive or not installed. Run option 3."
    fi

    echo -n "3. Tablet Mode Daemon: "
    if systemctl is-active --quiet cros-tablet-mode.service; then
        echo "[OK] Active and monitoring"
    else
        echo "[!] Inactive or not installed. Run option 4."
    fi

    echo -n "4. Hinge Angle Sensor: "
    for p in /sys/bus/iio/devices/iio:device*/in_angl_raw; do
        if [ -f "$p" ]; then
            echo "$(cat "$p")° ($p)"
            break
        fi
    done

    echo -n "5. Keyboard Backlight Brightness: "
    if [ -f "/sys/class/leds/chromeos::kbd_backlight/brightness" ]; then
        echo "$(cat /sys/class/leds/chromeos::kbd_backlight/brightness) / 100"
    else
        echo "Not available"
    fi
    echo "=================================================================="
    echo ""
    read -p "Press Enter to continue..." dummy
}

case "$1" in
    --all)
        install_touchscreen
        install_keyboard
        install_tablet
        exit 0
        ;;
    --touchscreen)
        install_touchscreen
        exit 0
        ;;
    --keyboard)
        install_keyboard
        exit 0
        ;;
    --tablet)
        install_tablet
        exit 0
        ;;
    --status)
        run_diagnostics
        exit 0
        ;;
esac

while true; do
    show_banner
    read -p "Select an option [1-6]: " opt
    case "$opt" in
        1)
            install_touchscreen
            install_keyboard
            install_tablet
            echo ""
            echo "[+] All components installed and configured successfully."
            read -p "Press Enter to return to menu..." dummy
            ;;
        2)
            install_touchscreen
            read -p "Press Enter to return to menu..." dummy
            ;;
        3)
            install_keyboard
            read -p "Press Enter to return to menu..." dummy
            ;;
        4)
            install_tablet
            read -p "Press Enter to return to menu..." dummy
            ;;
        5)
            run_diagnostics
            ;;
        6)
            echo "Exiting..."
            exit 0
            ;;
        *)
            echo "Invalid option."
            sleep 1
            ;;
    esac
done
