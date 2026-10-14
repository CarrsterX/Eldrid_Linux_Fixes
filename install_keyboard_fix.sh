#!/usr/bin/env bash
# install_keyboard_fix.sh
# Key remapping and Fn-mode toggle for HP Chromebook x360 14c (Eldrid) (ChromeOS Top Row <-> F1-F10)
#
# Credits and Acknowledgements:
# - Remapping Engine: keyd by rvaiya (https://github.com/rvaiya/keyd - MIT License)
# - Scancode Research: Chrultrabook Project & cros-keyboard-map by WeirdTreeThing
#   (https://github.com/WeirdTreeThing/cros-keyboard-map)

set -e

if [ "$EUID" -ne 0 ]; then
    echo "[!] Superuser privileges required."
    echo "[*] Elevating: sudo bash $0 $@"
    exec sudo bash "$0" "$@"
fi

echo "=================================================================="
echo " CHROMEBOOK ELDRID KEYBOARD REMAPPING CONFIGURATOR (KEYD) "
echo "=================================================================="

# 1. Verify build dependencies
echo "[*] Checking build dependencies (gcc, make, kernel-headers)..."
if ! command -v gcc &>/dev/null || ! command -v make &>/dev/null; then
    echo "[*] Installing required compiler toolchain packages..."
    dnf install -y gcc make kernel-headers git
fi

# 2. Compile and install keyd if not present
if ! command -v keyd &>/dev/null; then
    echo "[*] keyd binary not found. Cloning and building keyd from source..."
    BUILD_DIR=$(mktemp -d /tmp/keyd-build.XXXXXX)
    git clone --depth 1 https://github.com/rvaiya/keyd.git "$BUILD_DIR"
    pushd "$BUILD_DIR" > /dev/null
    make -j$(nproc)
    make install
    popd > /dev/null
    rm -rf "$BUILD_DIR"
    echo "[+] keyd successfully built and installed."
else
    echo "[*] keyd binary is already installed."
fi

# 3. Deploy keyd configuration
echo "[*] Deploying mapping profile to /etc/keyd/cros.conf..."
mkdir -p /etc/keyd

cat << 'CONF' > /etc/keyd/cros.conf
[ids]
k:0001:0001
k:0000:0000
*

# ==============================================================================
# DEFAULT MODE: ChromeOS Media Top Row Action Keys
# ==============================================================================
[main]
f1 = back
f2 = forward
f3 = refresh
f4 = f11
f5 = scale
f6 = brightnessdown
f7 = brightnessup
f8 = mute
f9 = volumedown
f10 = volumeup

# Lock Key (Lock / Padlock / Config keycode variants) -> Lock GNOME Screen (Super + L)
f13 = M-l
f14 = M-l
sleep = M-l
coffee = M-l
config = M-l
setup = M-l
prog1 = M-l

# Mode Toggle Shortcut: Left Shift + Meta (Super) + Esc
[shift+meta]
esc = toggle(function_keys)

# Convenience Navigation Shortcuts while holding Meta (Super / Search):
[meta]
f1 = f1
f2 = f2
f3 = f3
f4 = f4
f5 = f5
f6 = f6
f7 = f7
f8 = f8
f9 = f9
f10 = f10
left = home
right = end
up = pageup
down = pagedown
backspace = delete

# Alt + F6 / F7 -> Keyboard Backlight Illumination Control
[alt]
backspace = delete
brightnessdown = kbdillumdown
brightnessup = kbdillumup
f6 = kbdillumdown
f7 = kbdillumup

# ==============================================================================
# FUNCTION KEYS MODE: Direct Standard F1 - F10 (Fn Lock)
# Toggled with: Left Shift + Meta + Esc
# ==============================================================================
[function_keys]
f1 = f1
f2 = f2
f3 = f3
f4 = f4
f5 = f5
f6 = f6
f7 = f7
f8 = f8
f9 = f9
f10 = f10

# Lock key mapping maintained in Fn mode
f13 = M-l
f14 = M-l
sleep = M-l
coffee = M-l
config = M-l
setup = M-l
prog1 = M-l

# Holding Meta in Fn mode temporarily restores ChromeOS media actions
[function_keys+meta]
f1 = back
f2 = forward
f3 = refresh
f4 = f11
f5 = scale
f6 = brightnessdown
f7 = brightnessup
f8 = mute
f9 = volumedown
f10 = volumeup
left = home
right = end
up = pageup
down = pagedown
backspace = delete

# Alt + F6 / F7 illumination control maintained in Fn mode
[function_keys+alt]
backspace = delete
brightnessdown = kbdillumdown
brightnessup = kbdillumup
f6 = kbdillumdown
f7 = kbdillumup

# Toggle back to Default Mode using identical shortcut:
[function_keys+shift+meta]
esc = toggle(function_keys)
CONF

chmod 644 /etc/keyd/cros.conf

# 4. Enable and restart keyd service
echo "[*] Enabling and starting keyd service..."
systemctl daemon-reload
systemctl enable --now keyd.service
systemctl restart keyd.service

echo ""
echo "=================================================================="
echo " KEYBOARD CONFIGURATION DEPLOYED SUCCESSFULLY! "
echo "=================================================================="
echo "Service Status:"
systemctl status keyd.service --no-pager || true
echo ""
echo "APPLIED FEATURES:"
echo "  1. Lock Button: Mapped to Super+L (M-l) to lock GNOME Shell session."
echo "  2. Alt + F6 / F7 (Brightness): Controls keyboard backlight brightness."
echo "  3. LeftShift + Meta + Esc: Toggles between Media Keys and standard F1-F10."
echo "=================================================================="
