#!/usr/bin/env bash
# /usr/local/bin/fix-touchscreen.sh
# Userspace initialization for Goodix Touchscreen (GDIX0000)
# on HP Chromebook x360 14c Eldrid (Volteer / Intel Tiger Lake PCH).
#
# Technical Rationale:
# The Linux i2c_hid_acpi driver fails probe on initial boot because the
# coreboot AML interpreter executes the Sleep(300ms) in the _ON power resource
# semi-asynchronously relative to device probing. This script directly enforces
# the required hardware GPIO power sequence via userspace GPIO lines, bypassing
# ACPI timing dependencies.
#
# GPIO Pin Allocations (gpiochip0 / Intel Tiger Lake PCH):
#   Pin 72  (0x48):  enable-gpios -> VDD Power Rail (Active-High)
#   Pin 266 (0x10A): reset-gpios  -> Hardware Reset  (Active-Low: Pull High to Release)

set -e

DRIVER_PATH="/sys/bus/i2c/drivers/i2c_hid_acpi"
DEVICE="i2c-GDIX0000:00"
GPIO_CHIP="0"
PIN_VDD=72
PIN_RESET=266

log() { echo "[touchscreen-init] $*" | tee -a /var/log/touchscreen-init.log; }

log "Starting Goodix Touchscreen power sequencing..."

# 1. Unbind device if previously bound or failed during initial probe
if [ -e "${DRIVER_PATH}/${DEVICE}" ]; then
    log "Unbinding ${DEVICE} from i2c_hid_acpi driver..."
    echo "${DEVICE}" > "${DRIVER_PATH}/unbind" 2>/dev/null || true
    sleep 0.1
fi

# 2. Terminate any previous gpioset hold processes
killall gpioset 2>/dev/null || true
sleep 0.05

# 3. Hardware Electrical Reset Sequence:
#    Step A: Assert VDD (72=1), force Hardware Reset to Low / 0V (266=0) for 50ms
log "Step A: Asserting VDD and forcing Hardware Reset low..."
sleep 9999 | gpioset -c ${GPIO_CHIP} ${PIN_VDD}=1 ${PIN_RESET}=0 &
PID_RESET=$!
sleep 0.05
kill $PID_RESET 2>/dev/null || true

# 4. Step B: Maintain VDD (72=1), release Hardware Reset to 3.3V (266=1)
#    Spawns persistent background process to maintain GPIO line state during service lifetime
log "Step B: Releasing Hardware Reset and maintaining VDD active..."
sleep 99999999 | gpioset -c ${GPIO_CHIP} ${PIN_VDD}=1 ${PIN_RESET}=1 &
PID_HOLD=$!

# 5. Wait for Goodix controller firmware initialization (Datasheet: >= 150ms, margin: 400ms)
log "Waiting 400ms for Goodix controller firmware boot and stabilization..."
sleep 0.4

# 6. Ensure kernel modules are loaded
modprobe i2c_hid_acpi 2>/dev/null || true
modprobe i2c_hid 2>/dev/null || true

# 7. Bind device to driver
log "Binding ${DEVICE} to i2c_hid_acpi driver..."
if echo "${DEVICE}" > "${DRIVER_PATH}/bind" 2>/dev/null; then
    log "Device bind successful. Touchscreen initialized."
else
    if [ -e "${DRIVER_PATH}/${DEVICE}" ]; then
        log "Device is already bound (healthy state)."
    else
        log "WARNING: Device bind failed. Executing fallback retry..."
        sleep 0.2
        echo "${DEVICE}" > "${DRIVER_PATH}/bind" 2>/dev/null || log "ERROR: Fallback bind failed."
    fi
fi

log "Initialization complete. Active gpioset daemon PID: ${PID_HOLD}"
echo ${PID_HOLD} > /run/touchscreen-gpioset.pid
