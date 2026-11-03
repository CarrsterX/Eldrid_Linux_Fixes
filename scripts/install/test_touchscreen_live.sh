#!/usr/bin/env bash
# test_touchscreen_live.sh
# Diagnostic and live initialization script for Goodix Touchscreen (GDIX0000)
# Enables runtime testing on current session without requiring reboot.

set -e

if [ "$EUID" -ne 0 ]; then
    echo "[!] Superuser privileges required."
    echo "[*] Executing: sudo bash $0 $@"
    exec sudo bash "$0" "$@"
fi

echo "=================================================================="
echo " LIVE DIAGNOSTIC & INITIALIZATION: GOODIX TOUCHSCREEN (ELDRID) "
echo "=================================================================="

# 1. Terminate conflicting instances
echo "[*] Terminating previous gpioset instances..."
killall gpioset 2>/dev/null || true
sleep 0.2

# 2. Hardware GPIO power sequencing:
#    Pin 72:  VDD / Power Rail (Active-High)
#    Pin 266: Hardware Reset    (Active-Low)
echo "[*] Executing GPIO electrical power and reset sequence..."

# Step A: Assert VDD (72=1), hold Reset Low (266=0) for 50ms
sleep 9999 | gpioset -c 0 72=1 266=0 &
PID_RESET=$!
sleep 0.05
kill $PID_RESET 2>/dev/null || true

# Step B: Maintain VDD (72=1), release Reset High (266=1)
sleep 99999999 | gpioset -c 0 72=1 266=1 &
PID_HOLD=$!

echo "[*] Waiting 300ms for Goodix controller firmware initialization..."
sleep 0.3

# 3. Bind to i2c_hid_acpi driver
echo "[*] Binding to i2c_hid_acpi driver..."
if [ -e /sys/bus/i2c/drivers/i2c_hid_acpi/i2c-GDIX0000:00 ]; then
    echo "[*] Unbinding stale device handle..."
    echo "i2c-GDIX0000:00" > /sys/bus/i2c/drivers/i2c_hid_acpi/unbind 2>/dev/null || true
    sleep 0.2
fi

modprobe i2c_hid_acpi 2>/dev/null || true
if echo "i2c-GDIX0000:00" > /sys/bus/i2c/drivers/i2c_hid_acpi/bind 2>/dev/null; then
    echo "[+++] Device i2c-GDIX0000:00 bound successfully!"
else
    echo "[*] Device already bound or detection in progress."
fi

sleep 0.5

echo "=================================================================="
echo " KERNEL INPUT DEVICE STATUS: "
echo "=================================================================="
dmesg | tail -n 20 | grep -i -E "gdix|goodix|i2c_hid|hid-generic|input:" || true

echo ""
echo "[+] Touchscreen input node ready. Verify touch functionality on display."
echo "[+] Note: Background hold process will remain active for current session."
echo "=================================================================="
