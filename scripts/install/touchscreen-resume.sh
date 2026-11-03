#!/usr/bin/env bash
# /lib/systemd/system-sleep/touchscreen-resume.sh
# Systemd sleep/resume hook for Goodix Touchscreen (GDIX0000) on HP Chromebook x360 14c (Eldrid)

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
        # Release active GPIO hold process prior to suspend
        log "PRE-SUSPEND: releasing gpioset..."
        if [ -f "${PIDFILE}" ]; then
            OLD_PID=$(cat "${PIDFILE}")
            kill "${OLD_PID}" 2>/dev/null || true
            rm -f "${PIDFILE}"
        fi
        killall gpioset 2>/dev/null || true
        log "PRE-SUSPEND: complete."
        ;;

    post)
        log "POST-RESUME: re-initializing Goodix Touchscreen..."

        # 1. Unbind stale driver instance
        if [ -e "${DRIVER_PATH}/${DEVICE}" ]; then
            log "Unbinding ${DEVICE}..."
            echo "${DEVICE}" > "${DRIVER_PATH}/unbind" 2>/dev/null || true
        fi

        # 2. Terminate lingering gpioset processes
        killall gpioset 2>/dev/null || true
        sleep 0.05

        # 3. Assert VDD (72=1), hold Reset low (266=0) for 50ms
        log "Step A: VDD=1, RESET=0 for 50ms..."
        sleep 9999 | gpioset -c ${GPIO_CHIP} ${PIN_VDD}=1 ${PIN_RESET}=0 &
        PID_RESET=$!
        sleep 0.05
        kill $PID_RESET 2>/dev/null || true

        # 4. Release Reset high (266=1) and maintain VDD active
        log "Step B: VDD=1, RESET=1 (holding GPIO state)..."
        sleep 99999999 | gpioset -c ${GPIO_CHIP} ${PIN_VDD}=1 ${PIN_RESET}=1 &
        PID_HOLD=$!
        echo ${PID_HOLD} > "${PIDFILE}"

        # 5. Wait for Goodix controller firmware initialization
        log "Waiting 400ms for Goodix firmware boot..."
        sleep 0.4

        # 6. Ensure kernel modules are loaded
        modprobe i2c_hid_acpi 2>/dev/null || true
        modprobe i2c_hid 2>/dev/null || true

        # 7. Bind device to driver
        log "Binding ${DEVICE} to i2c_hid_acpi..."
        if echo "${DEVICE}" > "${DRIVER_PATH}/bind" 2>/dev/null; then
            log "POST-RESUME: Touchscreen successfully initialized. gpioset PID: ${PID_HOLD}"
        else
            if [ -e "${DRIVER_PATH}/${DEVICE}" ]; then
                log "POST-RESUME: Device already bound (OK)."
            else
                log "Retry 2: secondary reset cycle..."
                sleep 0.2
                if echo "${DEVICE}" > "${DRIVER_PATH}/bind" 2>/dev/null; then
                    log "POST-RESUME: Touchscreen initialized on retry."
                else
                    log "ERROR: Failed to bind ${DEVICE}."
                fi
            fi
        fi
        ;;
esac

exit 0
