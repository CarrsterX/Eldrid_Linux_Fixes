#!/usr/bin/env bash
# optimize_battery.sh - v3
# Optimización de batería 100% compatible con GNOME/KDE para HP Chromebook x360 14c (Eldrid)
#
# ESTRATEGIA CORRECTA:
# 1. NO se modifica ppd.conf (rompe tuned-ppd y quita los perfiles de GNOME).
# 2. Se crean perfiles en /etc/tuned/profiles/<nombre>/ con el MISMO nombre que los 
#    perfiles estándar (balanced, powersave, etc.). TuneD prioriza /etc/tuned/profiles
#    sobre /usr/lib/tuned/profiles, así GNOME sigue funcionando normal pero usa
#    nuestra versión mejorada del perfil.
# 3. Las optimizaciones de kernel (sysctl/udev/GRUB) se aplican globalmente y
#    no interfieren con nada.

set -e

if [ "$EUID" -ne 0 ]; then
    echo "[!] Requiere privilegios de administrador."
    exec sudo bash "$0" "$@"
fi

echo "=================================================================="
echo " OPTIMIZACION DE BATERIA GNOME-COMPATIBLE - HP ELDRID (v3)        "
echo "=================================================================="
echo ""

# Verificar que tuned-ppd no está caido antes de empezar
if ! systemctl is-active --quiet tuned-ppd.service; then
    echo "[!] tuned-ppd está caído. Restableciendo antes de continuar..."
    # Restaurar ppd.conf si fue modificado antes
    if grep -q "eldrid" /etc/tuned/ppd.conf 2>/dev/null; then
        cat > /etc/tuned/ppd.conf << 'PPD'
[main]
default=balanced
battery_detection=true
sysfs_acpi_monitor=true

[profiles]
power-saver=powersave
balanced=balanced
performance=throughput-performance

[battery]
balanced=balanced-battery
PPD
        chmod 644 /etc/tuned/ppd.conf
        echo "      -> ppd.conf restaurado al original"
    fi
    systemctl restart tuned-ppd.service
    sleep 2
fi

# ========================================================================
# PASO 1: Sobrescribir los perfiles estándar con versiones mejoradas para Eldrid
# TuneD busca primero en /etc/tuned/profiles/, luego en /usr/lib/tuned/profiles/
# Esto es el mecanismo de override correcto y documentado.
# ========================================================================

echo "[1/3] Creando perfiles TuneD optimizados en /etc/tuned/profiles/..."
echo "      (GNOME sigue usando los mismos nombres de perfil: balanced, powersave, etc.)"
echo ""

# --- balanced-battery: GNOME "Equilibrado" cuando está en batería ---
mkdir -p /etc/tuned/profiles/balanced-battery
cat > /etc/tuned/profiles/balanced-battery/tuned.conf << 'TUNED'
#
# Perfil: balanced-battery (override para HP Chromebook x360 14c Eldrid)
# GNOME "Equilibrado" en batería -> ppd -> este perfil
# Hereda del balanced-battery del sistema y añade optimizaciones de hardware.
#
[main]
summary=Balanced (Eldrid) - Balance rendimiento/bateria optimizado para HP Chromebook x360 14c
include=balanced

[cpu]
# Tiger Lake i3-1115G4: balance_power = ahorro sin sacrificar respuesta
energy_performance_preference=balance_power
boost=1

[video]
panel_power_savings=1

[audio]
timeout=10

[sysctl]
# Menos wakeups de disco en modo batería
vm.dirty_writeback_centisecs=6000
kernel.nmi_watchdog=0
TUNED
echo "      -> balanced-battery sobrescrito"

# --- powersave: GNOME "Ahorro de Energía" ---
mkdir -p /etc/tuned/profiles/powersave
cat > /etc/tuned/profiles/powersave/tuned.conf << 'TUNED'
#
# Perfil: powersave (override para HP Chromebook x360 14c Eldrid)
# GNOME "Ahorro de Energía" -> ppd -> este perfil
# Igual que el perfil estándar powersave + ajustes para Tiger Lake.
#
[main]
summary=Power Saver (Eldrid) - Maximo ahorro de energia para HP Chromebook x360 14c
# Hereda del powersave estándar del sistema
include=powersave

[cpu]
energy_performance_preference=power
boost=0

[acpi]
platform_profile=low-power|quiet

[eeepc_she]

[vm]

[audio]
timeout=10

[video]
radeon_powersave=dpm-battery, auto
panel_power_savings=3

[scsi_host]
alpm=min_power

[sysctl]
vm.dirty_writeback_centisecs=6000
kernel.nmi_watchdog=0
TUNED
echo "      -> powersave sobrescrito"

# throughput-performance: GNOME "Rendimiento" - no modificar (el stock es bueno para rendimiento)
echo "      -> throughput-performance: sin cambios (stock es óptimo para rendimiento)"

# ========================================================================
# PASO 2: Optimizaciones de kernel globales (no interfieren con GNOME/TuneD)
# ========================================================================
echo ""
echo "[2/3] Aplicando optimizaciones de kernel globales..."

# USB Autosuspend via udev (compatible con todos los perfiles)
cat > /etc/udev/rules.d/90-eldrid-battery-powersave.rules << 'UDEV'
# Optimizaciones de batería HP Chromebook x360 14c (Eldrid)
# Independiente del perfil de energía de GNOME
ACTION=="add", SUBSYSTEM=="usb", TEST=="power/control", ATTR{power/control}="auto"
ACTION=="add", SUBSYSTEM=="usb", TEST=="power/autosuspend_delay_ms", ATTR{power/autosuspend_delay_ms}="2000"
ACTION=="add", SUBSYSTEM=="pci", TEST=="power/control", ATTR{power/control}="auto"
UDEV
echo "      -> USB autosuspend: /etc/udev/rules.d/90-eldrid-battery-powersave.rules"

# Aplicar USB autosuspend ahora mismo
USB_COUNT=0
for U in /sys/bus/usb/devices/*/power/control; do
    [ -f "$U" ] && echo "auto" > "$U" 2>/dev/null && USB_COUNT=$((USB_COUNT+1)) || true
done
echo "      -> USB autosuspend activo en $USB_COUNT dispositivos"

# GRUB: parámetros de kernel que no dependen del perfil de energía
GRUB_CONF=/etc/default/grub
PARAMS_ADD=""
grep -q "pcie_aspm.policy=powersupersave" "$GRUB_CONF" 2>/dev/null || PARAMS_ADD="$PARAMS_ADD pcie_aspm.policy=powersupersave"
grep -q "nmi_watchdog=0" "$GRUB_CONF" 2>/dev/null              || PARAMS_ADD="$PARAMS_ADD nmi_watchdog=0"
grep -q "mem_sleep_default" "$GRUB_CONF" 2>/dev/null           || PARAMS_ADD="$PARAMS_ADD mem_sleep_default=deep"

if [ -n "$PARAMS_ADD" ] && [ -f "$GRUB_CONF" ]; then
    TRIM=$(echo "$PARAMS_ADD" | xargs)
    sed -i "s|GRUB_CMDLINE_LINUX=\"\(.*\)\"|GRUB_CMDLINE_LINUX=\"\1 $TRIM\"|" "$GRUB_CONF"
    grub2-mkconfig -o /boot/efi/EFI/fedora/grub.cfg 2>/dev/null || \
    grub2-mkconfig -o /boot/grub2/grub.cfg 2>/dev/null && \
    echo "      -> GRUB actualizado con:$PARAMS_ADD (activo en próximo boot)" || \
    echo "      [!] GRUB: ejecuta 'grub2-mkconfig' manualmente"
else
    echo "      -> GRUB: parámetros ya presentes"
fi

# ========================================================================
# PASO 3: Recargar TuneD con los nuevos perfiles (tuned-ppd sigue funcionando)
# ========================================================================
echo ""
echo "[3/3] Recargando TuneD (sin tocar ppd.conf)..."

udevadm control --reload-rules 2>/dev/null || true
systemctl reload tuned.service 2>/dev/null || systemctl restart tuned.service 2>/dev/null || true
# tuned-ppd no necesita reinicio, solo tuned
sleep 1

echo ""
echo "=================================================================="
echo " COMPLETADO - GNOME FUNCIONA NORMAL                               "
echo "=================================================================="
echo ""
echo "COMO FUNCIONA:"
echo ""
echo "  GNOME Settings         PPD API          TuneD Profile (mejorado)"
echo "  ──────────────────────────────────────────────────────────────────"
echo "  Ahorro de Energía  ->  power-saver  ->  powersave (Eldrid override)"
echo "  Equilibrado        ->  balanced     ->  balanced-battery (Eldrid override)"
echo "  Rendimiento        ->  performance  ->  throughput-performance (stock)"
echo ""
echo "  Los overrides en /etc/tuned/profiles/ tienen prioridad sobre"
echo "  /usr/lib/tuned/profiles/ sin modificar ppd.conf."
echo ""
echo "OPTIMIZACIONES ADICIONALES (globales, todos los perfiles):"
echo "  USB autosuspend: 2s (udev)"
echo "  PCIe ASPM: powersupersave (GRUB, proximo boot)"
echo "  Sleep: deep S3 (GRUB, proximo boot)"
echo ""
echo "ESTADO:"
tuned-adm active 2>/dev/null
systemctl is-active tuned-ppd.service && echo "tuned-ppd: OK (GNOME perfiles activos)" || echo "tuned-ppd: ERROR"
echo ""
echo "VERIFICAR: Abre GNOME Configuracion -> Energia"
echo "           Los perfiles deben aparecer normalmente."
echo ""
echo "EXTRA - Limitar carga al 80%:"
echo "  echo 80 | sudo tee /sys/class/power_supply/BAT0/charge_control_end_threshold"
echo ""
