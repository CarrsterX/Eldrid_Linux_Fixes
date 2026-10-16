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
    echo "  1) Instalar TODO (Touchscreen + Teclado + Modo Tablet) [Recomendado]"
    echo "  2) Instalar Fix de Touchscreen (Digitalizador Goodix I2C)"
    echo "  3) Instalar Fix de Teclado (Fila superior ChromeOS + F5 Overview + Bloqueo)"
    echo "  4) Instalar Demonio de Modo Tablet (Bisagra, Backlight, Teclas y Volumen)"
    echo "  5) Diagnóstico en vivo del sistema"
    echo "  6) Salir"
    echo "=================================================================="
}

install_touchscreen() {
    echo ""
    echo ">>> [1/3] INSTALANDO FIX DE TOUCHSCREEN..."
    bash "$DIR/install_fix.sh"
}

install_keyboard() {
    echo ""
    echo ">>> [2/3] INSTALANDO FIX DE TECLADO..."
    bash "$DIR/install_keyboard_fix.sh"
}

install_tablet() {
    echo ""
    echo ">>> [3/3] INSTALANDO MODO TABLET..."
    bash "$DIR/install_tablet_mode.sh"
}

run_diagnostics() {
    echo ""
    echo "=================================================================="
    echo " DIAGNÓSTICO EN VIVO DEL HARDWARE "
    echo "=================================================================="
    echo -n "1. Estado Touchscreen I2C: "
    if [ -d "/sys/bus/i2c/drivers/i2c_hid_acpi/i2c-GDIX0000:00" ]; then
        echo "[OK] Vinculado y activo (i2c-GDIX0000:00)"
    else
        echo "[!] No vinculado. Ejecuta la opción 2."
    fi

    echo -n "2. Servicio Keyd (Teclado): "
    if systemctl is-active --quiet keyd.service; then
        echo "[OK] Activo y ejecutándose"
    else
        echo "[!] Inactivo o no instalado. Ejecuta la opción 3."
    fi

    echo -n "3. Demonio Modo Tablet: "
    if systemctl is-active --quiet cros-tablet-mode.service; then
        echo "[OK] Activo y monitoreando"
    else
        echo "[!] Inactivo o no instalado. Ejecuta la opción 4."
    fi

    echo -n "4. Ángulo actual de la bisagra: "
    for p in /sys/bus/iio/devices/iio:device*/in_angl_raw; do
        if [ -f "$p" ]; then
            echo "$(cat "$p")° ($p)"
            break
        fi
    done

    echo -n "5. Brillo retroiluminación teclado: "
    if [ -f "/sys/class/leds/chromeos::kbd_backlight/brightness" ]; then
        echo "$(cat /sys/class/leds/chromeos::kbd_backlight/brightness) / 100"
    else
        echo "No disponible"
    fi
    echo "=================================================================="
    echo ""
    read -p "Presiona Enter para continuar..." dummy
}

# Manejo de argumentos por línea de comandos (--all, --touchscreen, --keyboard, --tablet, --status)
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

# Menú interactivo
while true; do
    show_banner
    read -p "Selecciona una opción [1-6]: " opt
    case "$opt" in
        1)
            install_touchscreen
            install_keyboard
            install_tablet
            echo ""
            echo "[+] Todos los componentes han sido instalados y configurados exitosamente."
            read -p "Presiona Enter para volver al menú..." dummy
            ;;
        2)
            install_touchscreen
            read -p "Presiona Enter para volver al menú..." dummy
            ;;
        3)
            install_keyboard
            read -p "Presiona Enter para volver al menú..." dummy
            ;;
        4)
            install_tablet
            read -p "Presiona Enter para volver al menú..." dummy
            ;;
        5)
            run_diagnostics
            ;;
        6)
            echo "Saliendo..."
            exit 0
            ;;
        *)
            echo "Opción no válida."
            sleep 1
            ;;
    esac
done
