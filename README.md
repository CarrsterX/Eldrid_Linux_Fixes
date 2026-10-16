# Eldrid Linux Fixes 🐧💻

A curated collection of hardware initialization scripts, kernel patches, and workarounds for Chromebooks based on the **Google Volteer / Eldrid** platform (Intel 11th Gen Tiger Lake, such as the HP Chromebook x360 14c) running native Linux distributions (Fedora, Arch Linux, Debian, Ubuntu, etc.) through **Submarine** or **Depthcharge / coreboot** firmware.

---

## 📋 Table of Contents
- [Hardware Features & Fixes Overview](#-hardware-features--fixes-overview)
- [🛠️ Step-by-Step Installation Guide](#️-step-by-step-installation-guide)
  - [Prerequisites & Repository Setup](#1-prerequisites--repository-setup)
  - [Fix 1: Goodix Touchscreen Digitizer](#2-fix-1-goodix-touchscreen-digitizer-gdix0000)
  - [Fix 2: Keyboard Remapping & Fn-Lock](#3-fix-2-keyboard-remapping--fn-lock)
  - [Fix 3: 2-in-1 Convertible Tablet Mode](#4-fix-3-2-in-1-convertible-tablet-mode)
  - [Fix 4: ChromeOS Fingerprint Sensor](#5-fix-4-chromeos-fingerprint-sensor-fpc--cros-fpmcu)
  - [All-in-One Full Hardware Setup](#6-all-in-one-full-hardware-setup)
- [🔍 Deep-Dive Technical Root Causes & Solutions](#-deep-dive-technical-root-causes--solutions)
- [👥 Acknowledgements & Credits](#-acknowledgements--credits)
- [📜 License](#-license)

---

## 🌟 Hardware Features & Fixes Overview

| Hardware Subsystem | Stock Behavior on Native Linux | Behavior After Applying Fix |
|---|---|---|
| **Touchscreen (`GDIX0000`)** | Fails probe with `-121` (I2C NACK / EREMOTEIO); non-responsive to touch. | Direct GPIO sequencing + 400ms stabilization enables full multi-touch on boot. |
| **Top-Row Keyboard** | Top row sends ChromeOS media keys only; lock key opens Settings instead of locking screen. | Adds dynamic **Fn Lock toggle** (`Shift+Meta+Esc`), Lock button $\to$ `Super+L`, and `Alt+F6/F7` backlight. |
| **2-in-1 Tablet Mode** | Folding screen does not disable keyboard/touchpad; backlight stays on; rapid motion causes false triggers. | Daemon tracks hinge angle, filters EC sensor noise (`500`), disables touchpad, keeps side volume buttons active. |
| **Fingerprint Sensor** | Upstream drivers panic with `fp doesn't support V1` on Tiger Lake FPC sensors. | Full **FpInfo V2** protocol support, PAM integration for `sudo`, Polkit dialogs, and GDM lock screen. |

---

## 🛠️ Step-by-Step Installation Guide

### 1. Prerequisites & Repository Setup

Ensure Git and basic system utilities are installed:

```bash
# On Fedora / RHEL:
sudo dnf install -y git libgpiod-utils iasl dracut gcc make kernel-headers

# Clone this repository:
git clone https://github.com/CarrsterX/Eldrid_Linux_Fixes.git
cd Eldrid_Linux_Fixes
```

---

### 2. Fix 1: Goodix Touchscreen Digitizer (`GDIX0000`)

You can test the touchscreen live in your current session first, or install the permanent boot service directly.

#### Step 1.1: Live Diagnostic Test (Optional, No Reboot Required)
Test the electrical GPIO sequence and immediately verify touchscreen responsiveness:
```bash
sudo ./test_touchscreen_live.sh
```
*Touch the display to confirm touch response.*

#### Step 1.2: Permanent Installation (Persistent Across Reboots)
Deploys both the userspace systemd GPIO service and the complementary initramfs ACPI table override:
```bash
sudo ./install_fix.sh
```

#### Step 1.3: Verify Status
```bash
systemctl status touchscreen-init.service
dmesg | grep -i -E "gdix|goodix|i2c_hid"
```

---

### 3. Fix 2: Keyboard Remapping & Fn-Lock

Configures the low-level `keyd` daemon to map ChromeOS top-row action keys, dynamic Fn toggle, and screen locking.

#### Step 2.1: Installation
```bash
sudo ./install_keyboard_fix.sh
```

#### Step 2.2: How to Use the Keyboard Features
- **Toggle Fn Lock Mode:** Press **`Left Shift + Meta (Search) + Esc`**
  - **Media Mode (Default):** Back, Forward, Refresh, Fullscreen, Overview, Brightness Down/Up, Mute, Volume Down/Up.
  - **Function Keys Mode:** Direct **F1, F2, F3 ... F10** (ideal for IDEs, terminal, and gaming).
- **Lock Screen:** Press the dedicated **Lock Key** (top right) $\to$ triggers **`Super + L`** (locks GNOME Shell immediately).
- **Keyboard Backlight Control:** Press **`Alt + F6`** (brightness down) or **`Alt + F7`** (brightness up).
- **Temporary Cross-Access:** In either mode, hold **`Meta (Search)`** while tapping any top-row key to use the opposite mode.

#### Step 2.3: Verification & Uninstallation
```bash
# Check service status:
systemctl status keyd.service

# To uninstall and restore default keyboard behavior:
sudo ./uninstall_keyboard_fix.sh
```

---

### 4. Fix 3: 2-in-1 Convertible Tablet Mode

Installs the `cros_tablet_daemon` service to detect folding into tablet orientation, inhibit the touchpad, silence typing, and shut off keyboard illumination.

#### Step 3.1: Installation
```bash
sudo ./install_tablet_mode.sh
```

#### Step 3.2: How It Operates
- **Instant Dual Detection:**
  - Directly listens to kernel `Tablet Mode Switch` (`GOOG0006:00` / `/dev/input/by-path/*GOOG0006*-event`) via non-blocking `evdev` and `select()` for zero-latency response.
  - IIO lid angle sensor (`cros-ec-lid-angle`) serves as secondary confirmation and fallback, filtering out ChromeOS EC transit noise (`500`).
- **Entering Tablet Mode:**
  - **Keyboard Backlight Auto-Off:** Reads current brightness, saves it, and writes `0` to `/sys/class/leds/chromeos::kbd_backlight/brightness`.
  - **Touchpad Inhibit:** Writes `1` to `/sys/class/input/input*/inhibited`.
  - **Dynamic Keyd Profile Switching:** Atomically switches `/etc/keyd/cros.conf` to `cros-tablet.profile`. 267 physical keys (Tab, Backspace, top-row action keys, letter/number matrix) are explicitly mapped to `noop`, completely preventing accidental inputs while holding the tablet.
  - **Chassis Volume Rocker Active:** Hardware side volume buttons (+ / -) remain 100% functional via libinput quirk `ModelTabletModeNoSuspend=1`.
- **Returning to Laptop Mode:**
  - Touchpad reactivated (`inhibited = 0`).
  - Exact previous keyboard backlight illumination level is restored.
  - Atomically switches back to `cros-laptop.profile` (all ChromeOS shortcuts, media actions, and Fn-mode restored).

#### Step 3.3: Verification & Uninstallation
```bash
# Check daemon status:
systemctl status cros-tablet-mode.service

# Live sensor reading (degrees):
cat /sys/bus/iio/devices/iio:device*/in_angl_raw

# To uninstall and restore default behavior:
sudo ./uninstall_tablet_mode.sh
```

---

### 5. Fix 4: ChromeOS Fingerprint Sensor (`FPC / CrOS FPMCU`)

Fingerprint support is provided via our companion repository **[Rust-FP-Eldrid](https://github.com/CarrsterX/Rust-FP-Eldrid)**, patched specifically for ChromeOS `FpInfo V2` protocol and GNOME integration.

#### Step 4.1: Install Build Dependencies & Clone
```bash
sudo dnf install -y git cargo gcc pam-devel
git clone https://github.com/CarrsterX/Rust-FP-Eldrid.git
cd Rust-FP-Eldrid
```

#### Step 4.2: Compile & Deploy
```bash
cargo build --release
sudo ./install_fingerprint.sh
```

#### Step 4.3: Enroll Fingerprint Template (As Normal User, WITHOUT Sudo)
```bash
rust-fp add index
```
*Follow on-screen instructions, placing and lifting your finger on the sensor until 100% complete.*

#### Step 4.4: Test Authentication
- **Terminal `sudo`:** Open terminal and run `sudo -k && sudo whoami`.
- **GNOME Lock Screen:** Lock screen (`Super + L`) and unlock by resting your finger on the sensor.
- **Polkit Elevation:** Open GNOME Disks or system settings requiring administrative authentication.

---

### 6. All-in-One Full Hardware Setup

To apply all three core fixes (Touchscreen, Keyboard, and Tablet Mode) in a single sequence on a fresh installation:

```bash
git clone https://github.com/CarrsterX/Eldrid_Linux_Fixes.git
cd Eldrid_Linux_Fixes

# 1. Apply Touchscreen Fix:
sudo ./install_fix.sh

# 2. Apply Keyboard & Fn Keys Fix:
sudo ./install_keyboard_fix.sh

# 3. Apply 2-in-1 Tablet Mode Daemon:
sudo ./install_tablet_mode.sh
```

---

## 🔍 Deep-Dive Technical Root Causes & Solutions

<details>
<summary><b>1. Goodix Touchscreen: ACPI Timing Race Condition vs. GPIO Userspace Solution</b></summary>

- **ACPI Device Path:** `\_SB_.PCI0.I2C1.H014` (`GDIX0000`, `PNP0C50` on bus `i2c-1` address `0x14`).
- **GPIO Lines:** Intel Tiger Lake PCH `gpiochip0`:
  - Pin 72 (`0x48`): `enable-gpios` (VDD Rail, active-high).
  - Pin 266 (`0x10A`): `reset-gpios` (Hardware Reset, active-low).
- **Failure Analysis:** Coreboot AML executes `Sleep(30ms)` asynchronously during `_ON`. Linux driver `i2c_hid_acpi` probes before the Goodix controller initializes, failing with `-121` (`EREMOTEIO`).
- **Solution:** Userspace systemd unit executes `/usr/local/bin/fix-touchscreen.sh` directly asserting Pin 72, holding Reset low for 50ms, releasing Reset to 3.3V, waiting a conservative 400ms margin, and binding `i2c_hid_acpi` explicitly.
</details>

<details>
<summary><b>2. Keyboard Remapping: Low-Level Keyd Architecture</b></summary>

- Chromebook keyboards lack physical F1–F12 keys.
- `/etc/keyd/cros.conf` defines a default layer matching ChromeOS top-row actions and a secondary layer `[function_keys]` emitting physical F1–F10.
- Lock key code variants (`f13`, `f14`, `sleep`, `coffee`, `config`, `setup`, `prog1`) are remapped to `M-l` (`Super + L`), hooking directly into GNOME Shell's screen-locking handler.
- Backlight illumination is bound to `kbdillumdown` and `kbdillumup` via `Alt + F6/F7`.
</details>

<details>
<summary><b>3. Tablet Mode: EC Sentinel Filtering & Physical Debounce</b></summary>

- ChromeOS EC reports lid hinge angle via IIO (`in_angl_raw`).
- Rapid movement causes accelerometers to register instability, causing the EC to return status code `500` (`LID_ANGLE_UNRELIABLE`).
- The daemon rejects values $\ge 500$ and non-physical angles ($< 0^\circ$ or $> 360^\circ$).
- A sustained temporal filter (5 ticks at 0.2s = 1.0s) ensures tablet mode is only engaged when the device is intentionally folded.
- Touchpad inhibition via sysfs eliminates palm touch errors on the back of the device while leaving side volume buttons active.
</details>

---

## 👥 Acknowledgements & Credits

This project builds upon the valuable work of open-source projects and community developers:

- **[rvaiya/keyd](https://github.com/rvaiya/keyd)**:  
  Author of `keyd`, the high-performance kernel-level uinput remapping daemon used for keyboard layer management.
- **[WeirdTreeThing/cros-keyboard-map](https://github.com/WeirdTreeThing/cros-keyboard-map)** & **[Chrultrabook](https://chrultrabook.com/)**:  
  Pioneering documentation and scancode tables for Chromebook top-row keyboards under Linux.
- **[ChocolateLoverRaj/rust-fp](https://github.com/ChocolateLoverRaj/rust-fp)** & **[yuexiaoyong-star/rust-fp](https://github.com/yuexiaoyong-star/rust-fp)**:  
  Foundational architecture for communicating with the ChromeOS FPMCU over D-Bus/PAM, forming the base of our [Rust-FP-Eldrid](https://github.com/CarrsterX/Rust-FP-Eldrid) companion project.

---

## 📜 License

Distributed under the [GNU General Public License v3.0](LICENSE).
