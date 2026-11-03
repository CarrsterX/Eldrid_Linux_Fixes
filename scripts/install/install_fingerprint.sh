#!/usr/bin/env bash
# install_fingerprint.sh
# Dual authentication (password & fingerprint) for GDM / GNOME Shell on HP Chromebook x360 14c (Eldrid)
# Deploys cros-fprint-bridge, configures PAM, removes 2000ms GDM latency, and installs resume hook.

set -e

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ "$EUID" -ne 0 ]; then
    echo "[!] Superuser privileges required."
    exec sudo bash "$0" "$@"
fi

TARGET_USER="${SUDO_USER:-$(loginctl list-sessions --no-legend 2>/dev/null | awk '$5 ~ /seat0/ {print $3}' | grep -vE 'gdm|root' | head -1)}"
TARGET_USER="${TARGET_USER:-carrster}"

echo "=================================================================="
echo " CONFIGURING DUAL AUTHENTICATION (PASSWORD OR FINGERPRINT)        "
echo " Target user: $TARGET_USER                                       "
echo "=================================================================="

# 1. Install D-Bus bridge
echo "[1/7] Installing cros-fprint-bridge.py to /usr/local/bin..."
cp -f "$DIR/cros-fprint-bridge.py" /usr/local/bin/cros-fprint-bridge.py
chmod 755 /usr/local/bin/cros-fprint-bridge.py

# 2. Deploy systemd bridge service
echo "[2/7] Creating systemd service cros-fprint-bridge.service..."
cat << 'UNIT' > /etc/systemd/system/cros-fprint-bridge.service
[Unit]
Description=ChromeOS Fingerprint to Fprint D-Bus Bridge for GDM
After=dbus.service rust-fp-dbus-interface.service
Conflicts=fprintd.service

[Service]
Type=simple
ExecStart=/usr/bin/python3 /usr/local/bin/cros-fprint-bridge.py
Restart=always
RestartSec=2s

[Install]
WantedBy=multi-user.target
UNIT
chmod 644 /etc/systemd/system/cros-fprint-bridge.service

# 3. Mask conflicting upstream fprintd
echo "[3/7] Masking upstream fprintd.service..."
systemctl mask fprintd.service 2>/dev/null || true
systemctl stop fprintd.service 2>/dev/null || true

# 4. Configure PAM for parallel password and fingerprint auth
echo "[4/7] Configuring GDM PAM profiles..."
cat << 'PAM_PASS' > /etc/pam.d/gdm-password
auth        [success=done ignore=ignore default=bad] pam_selinux_permit.so
auth        substack      gdm-password-auth-substack
-auth       optional      pam_gnome_keyring.so
-auth       optional      pam_oo7.so
auth        include       postlogin

account     required      pam_nologin.so
account     include       password-auth

password    substack       gdm-password-auth-substack
-password   optional       pam_gnome_keyring.so use_authtok
-password   optional       pam_oo7.so use_authtok

session     required      pam_selinux.so close
session     required      pam_loginuid.so
session     required      pam_selinux.so open
session     optional      pam_keyinit.so force revoke
session     required      pam_namespace.so
session     include       password-auth
-session    optional      pam_gnome_keyring.so auto_start
-session    optional      pam_oo7.so auto_start
session     include       postlogin
PAM_PASS
chmod 644 /etc/pam.d/gdm-password

cat << 'PAM_FP' > /etc/pam.d/gdm-fingerprint
#%PAM-1.0
auth        [success=done ignore=ignore default=bad] pam_selinux_permit.so
auth        required      pam_env.so
auth        sufficient    librust_fp_pam_module.so
auth        required      pam_deny.so

account     required      pam_nologin.so
account     include       password-auth

password    required      pam_deny.so

session     required      pam_selinux.so close
session     required      pam_loginuid.so
session     required      pam_selinux.so open
session     optional      pam_keyinit.so force revoke
session     required      pam_namespace.so
session     include       password-auth
-session    optional      pam_gnome_keyring.so auto_start
-session    optional      pam_oo7.so auto_start
session     include       postlogin
PAM_FP
chmod 644 /etc/pam.d/gdm-fingerprint

# 5. Zero-Lag instant unlock (drop 2000ms delay to 100ms)
echo "[5/7] Configuring zero-lag GDM unlock (GDM_MESSAGE_TIME_MULTIPLIER=0.05)..."
if ! grep -q "GDM_MESSAGE_TIME_MULTIPLIER" /etc/environment 2>/dev/null; then
    echo "GDM_MESSAGE_TIME_MULTIPLIER=0.05" >> /etc/environment
else
    sed -i 's/^GDM_MESSAGE_TIME_MULTIPLIER=.*/GDM_MESSAGE_TIME_MULTIPLIER=0.05/' /etc/environment
fi

mkdir -p /etc/systemd/user.conf.d /etc/systemd/system.conf.d
cat << 'CONF1' > /etc/systemd/user.conf.d/10-fast-unlock.conf
[Manager]
DefaultEnvironment="GDM_MESSAGE_TIME_MULTIPLIER=0.05"
DefaultTimeoutStopSec=10s
CONF1

cat << 'CONF2' > /etc/systemd/system.conf.d/10-fast-unlock.conf
[Manager]
DefaultEnvironment="GDM_MESSAGE_TIME_MULTIPLIER=0.05"
CONF2

if [ -f /etc/security/pam_env.conf ]; then
    if ! grep -q "GDM_MESSAGE_TIME_MULTIPLIER" /etc/security/pam_env.conf; then
        echo "GDM_MESSAGE_TIME_MULTIPLIER DEFAULT=0.05 OVERRIDE=0.05" >> /etc/security/pam_env.conf
    fi
fi

# Enable user linger and clean session stop
loginctl enable-linger "$TARGET_USER" 2>/dev/null || true
mkdir -p /etc/systemd/system/user@.service.d
cat << 'CONF3' > /etc/systemd/system/user@.service.d/timeout.conf
[Service]
TimeoutStopSec=10s
CONF3

# 6. Sleep / resume hook for FPMCU
echo "[6/7] Installing suspend/resume hook for fingerprint MCU..."
mkdir -p /lib/systemd/system-sleep
cp -f "$DIR/fingerprint-resume.sh" /lib/systemd/system-sleep/fingerprint-resume.sh
chmod +x /lib/systemd/system-sleep/fingerprint-resume.sh

# 7. Reload systemd and activate services
echo "[7/7] Reloading systemd and starting fingerprint bridge..."
systemctl daemon-reload
systemctl enable --now rust-fp-dbus-interface.service 2>/dev/null || true
systemctl restart rust-fp-dbus-interface.service 2>/dev/null || true
systemctl enable --now cros-fprint-bridge.service
systemctl restart cros-fprint-bridge.service

echo ""
echo "=================================================================="
echo " FINGERPRINT & GDM DUAL AUTH CONFIGURED SUCCESSFULLY!            "
echo "=================================================================="
