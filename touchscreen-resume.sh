#!/usr/bin/env bash
# /lib/systemd/system-sleep/touchscreen-resume.sh
#
# Hook de suspend/resume para el Touchscreen Goodix GDIX0000
# (Chromebook Eldrid / Volteer / Intel Tiger Lake)
#
# Cuando el sistema vuelve de la suspensión (post), el controlador I2C
# pierde el estado de los pines GPIO (VDD y Reset) y el driver i2c_hid_acpi
# queda sin dispositivo activo. Este hook re-ejecuta la secuencia de
# inicialización GPIO y re-vincula el driver.
#
# Instalación:
#   sudo cp touchscreen-resume.sh /lib/systemd/system-sleep/touchscreen-resume.sh
#   sudo chmod +x /lib/systemd/system-sleep/touchscreen-resume.sh
#
# Los scripts en /lib/systemd/system-sleep/ se invocan con dos argumentos:
#   $1 = "pre" (antes de suspender) | "post" (después de reanudar)
#   $2 = "suspend" | "hibernate" | "hybrid-sleep" | "suspend-then-hibernate"

LOGFILE="/var/log/touchscreen-init.log"
DRIVER_PATH="/sys/bus/i2c/drivers/i2c_hid_acpi"
DEVICE="i2c-GDIX0000:00"
GPIO_CHIP="0"
PIN_VDD=72
PIN_RESET=266
PIDFILE="/run/touchscreen-gpioset.pid"

log() { echo "[touchscreen-resume] $(date '+%Y-%m-%d %H:%M:%S') $*" | tee -a "${LOGFILE}"; }

case "$1" in
    pre)
        # Antes de suspender: liberar el gpioset activo para que el kernel
        # pueda tomar control de los pines durante el suspend sin conflictos.
        log "PRE-SUSPEND: liberando gpioset (PID=$(cat ${PIDFILE} 2>/dev/null || echo 'N/A'))..."
        if [ -f "${PIDFILE}" ]; then
            OLD_PID=$(cat "${PIDFILE}")
            kill "${OLD_PID}" 2>/dev/null || true
            rm -f "${PIDFILE}"
        fi
        # Matar cualquier gpioset residual
        killall gpioset 2>/dev/null || true
        log "PRE-SUSPEND: listo."
        ;;

    post)
        log "POST-RESUME: re-inicializando Touchscreen Goodix GDIX0000..."

        # 1. Desconectar driver si quedó en estado inconsistente
        if [ -e "${DRIVER_PATH}/${DEVICE}" ]; then
            log "Desvinculando ${DEVICE}..."
            echo "${DEVICE}" > "${DRIVER_PATH}/unbind" 2>/dev/null || true
        fi

        # 2. Matar cualquier gpioset residual del ciclo anterior
        killall gpioset 2>/dev/null || true
        sleep 0.05

        # 3. Paso A: VDD ON, Reset activo bajo (50ms)
        log "Paso A: VDD=1, RESET=0 durante 50ms..."
        sleep 9999 | gpioset -c ${GPIO_CHIP} ${PIN_VDD}=1 ${PIN_RESET}=0 &
        PID_RESET=$!
        sleep 0.05
        kill $PID_RESET 2>/dev/null || true

        # 4. Paso B: Mantener VDD ON, liberar Reset (nivel alto)
        #    El proceso debe quedar vivo para mantener los pines activos.
        log "Paso B: VDD=1, RESET=1 (manteniendo pines activos)..."
        sleep 99999999 | gpioset -c ${GPIO_CHIP} ${PIN_VDD}=1 ${PIN_RESET}=1 &
        PID_HOLD=$!
        echo ${PID_HOLD} > "${PIDFILE}"

        # 5. Esperar arranque del firmware Goodix (≥150ms, usamos 400ms)
        log "Esperando 400ms para boot del firmware Goodix..."
        sleep 0.4

        # 6. Asegurar que el módulo esté cargado
        modprobe i2c_hid_acpi 2>/dev/null || true
        modprobe i2c_hid 2>/dev/null || true

        # 7. Re-vincular el driver
        log "Vinculando ${DEVICE} con i2c_hid_acpi..."
        if echo "${DEVICE}" > "${DRIVER_PATH}/bind" 2>/dev/null; then
            log "POST-RESUME: Touchscreen re-inicializado correctamente. PID gpioset: ${PID_HOLD}"
        else
            if [ -e "${DRIVER_PATH}/${DEVICE}" ]; then
                log "POST-RESUME: El dispositivo ya está vinculado (OK)."
            else
                # Segundo intento con ciclo adicional de reset
                log "Intento 2: ciclo adicional de reset..."
                sleep 0.2
                if echo "${DEVICE}" > "${DRIVER_PATH}/bind" 2>/dev/null; then
                    log "POST-RESUME: Touchscreen inicializado en el segundo intento."
                else
                    log "ERROR: No se pudo vincular ${DEVICE}. Verifica con: systemctl status touchscreen-init"
                fi
            fi
        fi
        ;;
esac

exit 0
