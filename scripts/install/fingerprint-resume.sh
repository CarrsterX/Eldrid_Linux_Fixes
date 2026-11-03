#!/usr/bin/env bash
# /lib/systemd/system-sleep/fingerprint-resume.sh
# Systemd sleep hook for ChromeOS FPMCU / rust-fp on HP Chromebook x360 14c (Eldrid)

LOGFILE="/var/log/fingerprint-resume.log"

log() {
    echo "[fingerprint-resume] $(date '+%Y-%m-%d %H:%M:%S') $*" | tee -a "${LOGFILE}" 2>/dev/null || echo "$*"
}

case "$1" in
    pre)
        # Release FPMCU D-Bus context prior to sleep
        systemctl stop rust-fp-dbus-interface.service 2>/dev/null || true
        killall -9 rust-fp-dbus-interface 2>/dev/null || true
        ;;

    post)
        # Re-initialize daemon on wake before GDM prompts
        sleep 0.1
        systemctl restart rust-fp-dbus-interface.service 2>/dev/null || true
        systemctl restart cros-fprint-bridge.service 2>/dev/null || true
        ;;
esac

exit 0

