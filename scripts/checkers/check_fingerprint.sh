#!/usr/bin/env bash
# check_fingerprint.sh
# Diagnostic checker for ChromeOS Fingerprint Sensor & GDM Dual Auth

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BOLD='\033[1m'; NC='\033[0m'
ok()    { echo -e "  ${GREEN}✓${NC} $*"; }
fail()  { echo -e "  ${RED}✗${NC} $*"; }
warn()  { echo -e "  ${YELLOW}~${NC} $*"; }

echo -e "\n${BOLD}=== [Fingerprint & Dual Auth Diagnostics] ===${NC}"

# 1. Hardware device node (SPI / CrOS FPMCU)
if dmesg 2>/dev/null | grep -i -E "cros.*fpmcu|fpc" | tail -1 | grep -q -v -i "error"; then
    ok "ChromeOS FPMCU driver detected in dmesg: $(dmesg | grep -i -E "cros.*fpmcu|fpc" | tail -1)"
elif ls /dev/cros_fp* 1>/dev/null 2>&1; then
    ok "Device node /dev/cros_fp detected"
else
    warn "Direct FPMCU device node not visible (may require root or driver probe)"
fi

# 2. D-Bus interface
if gdbus call --system --dest net.reactivated.Fprint --object-path /net/reactivated/Fprint/Manager --method net.reactivated.Fprint.Manager.GetDefaultDevice >/dev/null 2>&1; then
    ok "D-Bus service net.reactivated.Fprint is active and reporting device"
elif systemctl is-active --quiet cros-fprint-bridge.service 2>/dev/null; then
    ok "cros-fprint-bridge.service is active"
elif systemctl is-active --quiet rust-fp-dbus-interface.service 2>/dev/null; then
    ok "rust-fp-dbus-interface.service is active"
else
    warn "Fingerprint D-Bus service is inactive"
fi

# 3. GDM latency multiplier (Fast unlock)
if grep -q "GDM_MESSAGE_TIME_MULTIPLIER=0.05" /etc/environment 2>/dev/null; then
    ok "Zero-lag GDM unlock active: GDM_MESSAGE_TIME_MULTIPLIER=0.05 in /etc/environment"
else
    warn "GDM_MESSAGE_TIME_MULTIPLIER not set to 0.05 in /etc/environment (may experience 2s auth delay)"
fi

# 4. Post-suspend resume hook
if [ -x "/lib/systemd/system-sleep/fingerprint-resume.sh" ]; then
    ok "Sleep resume hook installed and executable: /lib/systemd/system-sleep/fingerprint-resume.sh"
else
    fail "Sleep resume hook missing or not executable (/lib/systemd/system-sleep/fingerprint-resume.sh)"
fi

# 5. PAM GDM profiles
if [ -f "/etc/pam.d/gdm-fingerprint" ]; then
    ok "PAM profile /etc/pam.d/gdm-fingerprint present"
else
    warn "PAM profile /etc/pam.d/gdm-fingerprint not configured"
fi
