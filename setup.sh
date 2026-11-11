#!/usr/bin/env bash
# setup.sh
# Master Suite Installer and Diagnostic Tool for HP Chromebook x360 14c (Eldrid / Google Volteer)
# Orchestrates modules in scripts/install, scripts/checkers, and scripts/uninstall.

set -e

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="$DIR/scripts/install"
CHECK_DIR="$DIR/scripts/checkers"
UNINSTALL_DIR="$DIR/scripts/uninstall"

if [ "$EUID" -ne 0 ]; then
    echo "[!] Superuser privileges required. Re-launching with sudo..."
    exec sudo bash "$0" "$@"
fi

show_banner() {
    clear 2>/dev/null || true
    echo "=================================================================="
    echo "       HP CHROMEBOOK x360 14c (ELDRID) - LINUX HARDWARE SUITE     "
    echo "=================================================================="
    echo "  1) Install ALL Fixes (Touchscreen, Keyboard, Tablet, Battery, Fingerprint)"
    echo "  2) Install Specific Module..."
    echo "  3) Run Comprehensive Diagnostics (Check All Fixes)"
    echo "  4) Run Diagnostics on Specific Module..."
    echo "  5) Uninstall Modules..."
    echo "  6) Manage / Update Submarine Bootloader (KERN-A)"
    echo "  7) Exit"
    echo "=================================================================="
}

install_all() {
    echo ""
    echo ">>> [1/5] INSTALLING TOUCHSCREEN FIX..."
    bash "$INSTALL_DIR/install_touchscreen.sh"
    echo ""
    echo ">>> [2/5] INSTALLING KEYBOARD REMAPPING..."
    bash "$INSTALL_DIR/install_keyboard.sh"
    echo ""
    echo ">>> [3/5] INSTALLING TABLET MODE DAEMON..."
    bash "$INSTALL_DIR/install_tablet.sh"
    echo ""
    echo ">>> [4/5] APPLYING BATTERY & S0ix OPTIMIZATIONS..."
    bash "$INSTALL_DIR/optimize_battery.sh"
    echo ""
    echo ">>> [5/5] CONFIGURING FINGERPRINT & GDM DUAL AUTH..."
    bash "$INSTALL_DIR/install_fingerprint.sh"
    echo ""
    echo "[+] All hardware fixes deployed successfully!"
}

menu_install_module() {
    echo ""
    echo "Select module to install:"
    echo "  1) Touchscreen Digitizer (Goodix I2C)"
    echo "  2) Keyboard Remapping & Fn-Lock (Keyd)"
    echo "  3) 2-in-1 Tablet Mode Daemon (Hinge, Touchpad & Key Management)"
    echo "  4) Battery Life & Native S0ix Sleep (TuneD + EPP + ASPM)"
    echo "  5) Fingerprint Sensor & GDM Dual Auth (FpInfo V2 + Zero-Lag)"
    echo "  6) Return to Main Menu"
    read -p "Select option [1-6]: " m_opt
    case "$m_opt" in
        1) bash "$INSTALL_DIR/install_touchscreen.sh" ;;
        2) bash "$INSTALL_DIR/install_keyboard.sh" ;;
        3) bash "$INSTALL_DIR/install_tablet.sh" ;;
        4) bash "$INSTALL_DIR/optimize_battery.sh" ;;
        5) bash "$INSTALL_DIR/install_fingerprint.sh" ;;
        6) return ;;
        *) echo "Invalid option." ;;
    esac
}

menu_check_module() {
    echo ""
    echo "Select subsystem to diagnose:"
    echo "  1) Touchscreen Digitizer"
    echo "  2) Keyboard Remapping"
    echo "  3) 2-in-1 Tablet Mode"
    echo "  4) Battery & Sleep Mode"
    echo "  5) Fingerprint & Dual Auth"
    echo "  6) Return to Main Menu"
    read -p "Select option [1-6]: " c_opt
    case "$c_opt" in
        1) bash "$CHECK_DIR/check_touchscreen.sh" ;;
        2) bash "$CHECK_DIR/check_keyboard.sh" ;;
        3) bash "$CHECK_DIR/check_tablet.sh" ;;
        4) bash "$CHECK_DIR/check_battery.sh" ;;
        5) bash "$CHECK_DIR/check_fingerprint.sh" ;;
        6) return ;;
        *) echo "Invalid option." ;;
    esac
}

menu_uninstall() {
    echo ""
    echo "Select component to uninstall:"
    echo "  1) Touchscreen Services & Hooks"
    echo "  2) Keyboard Configuration (Restore default kernel map)"
    echo "  3) Tablet Mode Daemon (Restore standard input states)"
    echo "  4) Battery Profile Overrides (Restore default TuneD)"
    echo "  5) Fingerprint Bridge & Custom PAM"
    echo "  6) Uninstall ALL Components"
    echo "  7) Return to Main Menu"
    read -p "Select option [1-7]: " u_opt
    case "$u_opt" in
        1) bash "$UNINSTALL_DIR/uninstall_touchscreen.sh" ;;
        2) bash "$UNINSTALL_DIR/uninstall_keyboard.sh" ;;
        3) bash "$UNINSTALL_DIR/uninstall_tablet.sh" ;;
        4) bash "$UNINSTALL_DIR/uninstall_battery.sh" ;;
        5) bash "$UNINSTALL_DIR/uninstall_fingerprint.sh" ;;
        6) bash "$UNINSTALL_DIR/uninstall_all.sh" ;;
        7) return ;;
        *) echo "Invalid option." ;;
    esac
}

# CLI Argument parsing
case "$1" in
    --all)
        install_all
        exit 0
        ;;
    --touchscreen)
        bash "$INSTALL_DIR/install_touchscreen.sh"
        exit 0
        ;;
    --keyboard)
        bash "$INSTALL_DIR/install_keyboard.sh"
        exit 0
        ;;
    --tablet)
        bash "$INSTALL_DIR/install_tablet.sh"
        exit 0
        ;;
    --battery)
        bash "$INSTALL_DIR/optimize_battery.sh"
        exit 0
        ;;
    --fingerprint)
        bash "$INSTALL_DIR/install_fingerprint.sh"
        exit 0
        ;;
    --check|--status)
        bash "$CHECK_DIR/check_all.sh"
        exit 0
        ;;
    --check-touchscreen)
        bash "$CHECK_DIR/check_touchscreen.sh"
        exit 0
        ;;
    --check-keyboard)
        bash "$CHECK_DIR/check_keyboard.sh"
        exit 0
        ;;
    --check-tablet)
        bash "$CHECK_DIR/check_tablet.sh"
        exit 0
        ;;
    --check-battery)
        bash "$CHECK_DIR/check_battery.sh"
        exit 0
        ;;
    --check-fingerprint)
        bash "$CHECK_DIR/check_fingerprint.sh"
        exit 0
        ;;
    --uninstall-all)
        bash "$UNINSTALL_DIR/uninstall_all.sh"
        exit 0
        ;;
    --uninstall-touchscreen)
        bash "$UNINSTALL_DIR/uninstall_touchscreen.sh"
        exit 0
        ;;
    --uninstall-keyboard)
        bash "$UNINSTALL_DIR/uninstall_keyboard.sh"
        exit 0
        ;;
    --uninstall-tablet)
        bash "$UNINSTALL_DIR/uninstall_tablet.sh"
        exit 0
        ;;
    --uninstall-battery)
        bash "$UNINSTALL_DIR/uninstall_battery.sh"
        exit 0
        ;;
    --uninstall-fingerprint)
        bash "$UNINSTALL_DIR/uninstall_fingerprint.sh"
        exit 0
        ;;
    --submarine)
        shift
        bash "$DIR/scripts/update_submarine.sh" "$@"
        exit 0
        ;;
esac

# Interactive loop
while true; do
    show_banner
    read -p "Select an option [1-7]: " opt
    case "$opt" in
        1)
            install_all
            echo ""
            read -p "Press Enter to return to menu..." dummy
            ;;
        2)
            menu_install_module
            echo ""
            read -p "Press Enter to return to menu..." dummy
            ;;
        3)
            bash "$CHECK_DIR/check_all.sh"
            echo ""
            read -p "Press Enter to return to menu..." dummy
            ;;
        4)
            menu_check_module
            echo ""
            read -p "Press Enter to return to menu..." dummy
            ;;
        5)
            menu_uninstall
            echo ""
            read -p "Press Enter to return to menu..." dummy
            ;;
        6)
            bash "$DIR/scripts/update_submarine.sh"
            echo ""
            read -p "Press Enter to return to menu..." dummy
            ;;
        7)
            echo "Exiting..."
            exit 0
            ;;
        *)
            echo "Invalid option."
            sleep 1
            ;;
    esac
done
