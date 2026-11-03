# Eldrid Linux Fixes 🐧💻

A curated collection of hardware initialization scripts, kernel patches, daemons, and power optimizations for Chromebooks based on the **Google Volteer / Eldrid** platform (Intel 11th Gen Tiger Lake, such as the **HP Chromebook x360 14c**) running native Linux distributions (**Fedora, Arch Linux, Debian, Ubuntu**, etc.) via **Submarine** or **Depthcharge / coreboot** firmware.

---

## 📋 Table of Contents
- [Hardware Features & Fixes Overview](#-hardware-features--fixes-overview)
- [📁 Repository Architecture](#-repository-architecture)
- [🚀 Quick Start (Master Suite)](#-quick-start-master-suite)
- [🛠️ Step-by-Step Installation & Diagnostic Guide](#️-step-by-step-installation--diagnostic-guide)
  - [1. Prerequisites & Setup](#1-prerequisites--setup)
  - [2. Fix 1: Goodix Touchscreen Digitizer (`GDIX0000`)](#2-fix-1-goodix-touchscreen-digitizer-gdix0000)
  - [3. Fix 2: Keyboard Remapping & Fn-Lock](#3-fix-2-keyboard-remapping--fn-lock)
  - [4. Fix 3: 2-in-1 Convertible Tablet Mode](#4-fix-3-2-in-1-convertible-tablet-mode)
  - [5. Fix 4: Battery & Native S0ix Sleep Optimization](#5-fix-4-battery--native-s0ix-sleep-optimization)
  - [6. Fix 5: ChromeOS Fingerprint Sensor & Zero-Lag Unlock](#6-fix-5-chromeos-fingerprint-sensor--zero-lag-unlock)
- [🔍 Deep-Dive Technical Root Causes & Solutions](#-deep-dive-technical-root-causes--solutions)
- [👥 Acknowledgements & Credits](#-acknowledgements--credits)
- [📜 License](#-license)

---

## 🌟 Hardware Features & Fixes Overview

| Hardware Subsystem | Stock Behavior on Native Linux | Behavior After Applying Fix |
|---|---|---|
| **Touchscreen (`GDIX0000`)** | Fails probe with `-121` (I2C NACK / `EREMOTEIO`); non-responsive to touch. | Direct GPIO sequencing + 400ms stabilization enables full multi-touch on boot and reliable post-resume recovery. |
| **Top-Row Keyboard** | Sends media keys only; lock key opens Settings; side volume buttons mute in tablet mode. | Dynamic **Fn Lock toggle** (`Shift+Meta+Esc`), ChromeOS Overview key $\to$ `Super`, and `Alt+F6/F7` backlight control. |
| **2-in-1 Tablet Mode** | Folding screen does not disable keyboard/touchpad; backlight stays on; rapid motion causes false triggers. | Daemon tracks hinge angle, filters EC sensor noise (`500`), disables touchpad, keeps side volume buttons active. |
| **Battery & Sleep Drain** | Legacy S3 (`deep`) leaks ~1.9W (~4.2%/h); secondary voltage rails remain energized. | Native **S0ix (`s2idle`)** drops suspend drain to ~0.4W (>80% reduction), TuneD power profile, and EC 80% charge limit. |
| **Fingerprint Sensor** | Upstream drivers panic with `fp doesn't support V1` on Tiger Lake FPC sensors. | Full **FpInfo V2** protocol support, PAM integration (`sudo`, Polkit, GDM), sleep recovery hook, and Zero-Lag unlock. |

---

## 📁 Repository Architecture

The repository is cleanly partitioned into a master orchestrator in the root and modular subdirectories:

```text
Eldrid_Linux_Fixes/
├── setup.sh                     # Master interactive configurator & CLI runner
├── README.md                    # Comprehensive documentation & diagnostic guides
├── LICENSE                      # GNU General Public License v3.0
├── .gitignore                   # Git exclusion rules (keeps local notes private)
└── scripts/
    ├── install/                 # Installation scripts and service definitions
    │   ├── apply_touchscreen_fix.py
    │   ├── cros-fprint-bridge.py
    │   ├── cros-laptop.profile
    │   ├── cros_tablet_daemon.py
    │   ├── cros-tablet.profile
    │   ├── fingerprint-resume.sh
    │   ├── fix-touchscreen.sh
    │   ├── install_battery.sh
    │   ├── install_fingerprint.sh
    │   ├── install_keyboard.sh
    │   ├── install_tablet.sh
    │   ├── install_touchscreen.sh
    │   ├── optimize_battery.sh
    │   ├── test_touchscreen_live.sh
    │   ├── touchscreen-init.service
    │   └── touchscreen-resume.sh
    │
    ├── checkers/                # Deep diagnostic checkers with live sensors
    │   ├── check_all.sh         # Master test runner (evaluates all subsystems)
    │   ├── check_battery.sh     # Tests s2idle, EPP, TuneD, PCIe ASPM, EC threshold
    │   ├── check_fingerprint.sh # Tests FPMCU, D-Bus bridge, PAM, GDM multiplier
    │   ├── check_keyboard.sh    # Tests keyd service, uinput virtual device, backlight
    │   ├── check_tablet.sh      # Reads IIO hinge angle, GOOG0006 switch, quirks
    │   └── check_touchscreen.sh # Tests I2C driver binding, input nodes, resume logs
    │
    └── uninstall/               # Clean uninstallation and restoration scripts
        ├── uninstall_all.sh
        ├── uninstall_battery.sh
        ├── uninstall_fingerprint.sh
        ├── uninstall_keyboard.sh
        ├── uninstall_tablet.sh
        └── uninstall_touchscreen.sh
```

---

## 🚀 Quick Start (Master Suite)

The fastest and most reliable way to configure or diagnose your Chromebook is using **`setup.sh`**:

```bash
# Clone the repository:
git clone https://github.com/CarrsterX/Eldrid_Linux_Fixes.git
cd Eldrid_Linux_Fixes

# Launch interactive menu (Install, Diagnose, or Uninstall):
sudo ./setup.sh

# Or unattended full installation of all modules:
sudo ./setup.sh --all

# Run comprehensive hardware diagnostics across all subsystems:
sudo ./setup.sh --check

# Uninstall all modules and restore stock hardware defaults:
sudo ./setup.sh --uninstall-all
```

---

## 🛠️ Step-by-Step Installation & Diagnostic Guide

### 1. Prerequisites & Setup

Ensure Git and basic build utilities are installed:

```bash
# On Fedora / RHEL:
sudo dnf install -y git libgpiod-utils iasl dracut gcc make kernel-headers

cd Eldrid_Linux_Fixes
```

---

### 2. Fix 1: Goodix Touchscreen Digitizer (`GDIX0000`)

#### Step 1.1: Live Diagnostic Test (Optional, No Reboot Required)
Test the electrical GPIO sequence and immediately verify touchscreen responsiveness:
```bash
sudo ./scripts/install/test_touchscreen_live.sh
```
*Touch the display to confirm touch response.*

#### Step 1.2: Permanent Installation (Persistent Across Reboots & Suspend)
Deploys the ACPI SSDT table override via Dracut and installs the automatic suspend/resume hook:
```bash
sudo ./scripts/install/install_touchscreen.sh
```

#### Step 1.3: Run Diagnostic Checker & Verify Status
```bash
# Run automated touchscreen checker:
sudo ./scripts/checkers/check_touchscreen.sh

# Or manual verification commands:
systemctl status touchscreen-init.service
grep 'POST-RESUME' /var/log/touchscreen-init.log
dmesg | grep -i -E "gdix|goodix|i2c_hid"
```

#### Step 1.4: Uninstallation
```bash
sudo ./scripts/uninstall/uninstall_touchscreen.sh
```

---

### 3. Fix 2: Keyboard Remapping & Fn-Lock

Configures the low-level `keyd` daemon to map ChromeOS top-row action keys, dynamic Fn toggle, and screen locking.

#### Step 2.1: Installation
```bash
sudo ./scripts/install/install_keyboard.sh
```

#### Step 2.2: How to Use Keyboard Features
- **Toggle Fn Lock Mode:** Press **`Left Shift + Meta (Search) + Esc`**
  - **Media Mode (Default):** Back, Forward, Refresh, Fullscreen, Overview (F5), Brightness Down/Up, Mute, Volume Down/Up.
  - **Function Keys Mode:** Direct **F1, F2, F3 ... F10** (ideal for IDEs, terminal, and gaming).
- **F5 Action Key (ChromeOS Overview):** Mapped directly to **`Super` (`leftmeta`)**, opening GNOME Activities or KDE Plasma Window Overview instantly.
- **Lock Screen:** Press dedicated **Lock Key** (top right) $\to$ triggers **`Super + L`** (locks GNOME Shell immediately).
- **Keyboard Backlight Control:** Press **`Alt + F6`** (brightness down) or **`Alt + F7`** (brightness up).
- **Temporary Cross-Access:** In either mode, hold **`Meta (Search)`** while tapping any top-row key to use the opposite mode.

#### Step 2.3: Run Diagnostic Checker & Verify Status
```bash
# Run automated keyboard checker:
sudo ./scripts/checkers/check_keyboard.sh

# Check keyd service status:
systemctl status keyd.service
```

#### Step 2.4: Uninstallation
```bash
sudo ./scripts/uninstall/uninstall_keyboard.sh
```

---

### 4. Fix 3: 2-in-1 Convertible Tablet Mode

Installs the `cros_tablet_daemon` service to detect folding into tablet orientation, inhibit the touchpad, silence typing, and shut off keyboard illumination.

#### Step 3.1: Installation
```bash
sudo ./scripts/install/install_tablet.sh
```

#### Step 3.2: How It Operates
- **Instant Dual Detection:** Listens to kernel `Tablet Mode Switch` (`GOOG0006:00`) via non-blocking evdev with IIO lid angle sensor fallback.
- **Entering Tablet Mode:** Keyboard backlight turns off (saves saved brightness level), touchpad is inhibited (`inhibited = 1`), and `/etc/keyd/cros.conf` atomically switches to `cros-tablet.profile` (mutes 267 physical keys).
- **Chassis Volume Rocker Active:** Hardware side volume buttons (+ / -) remain 100% functional via libinput quirk `ModelTabletModeNoSuspend=1`.
- **Returning to Laptop Mode:** Touchpad reactivated, exact keyboard backlight brightness is restored, and laptop profile is atomically reloaded.
- **Intelligent Backlight Idle Timeout:** Turns off keyboard LEDs after 30 seconds of inactivity to save battery. Touching any key or touchpad instantly restores illumination.

#### Step 3.3: Run Diagnostic Checker & Verify Status
```bash
# Run automated tablet mode checker:
sudo ./scripts/checkers/check_tablet.sh

# Live sensor reading (degrees):
cat /sys/bus/iio/devices/iio:device*/in_angl_raw
```

#### Step 3.4: Uninstallation
```bash
sudo ./scripts/uninstall/uninstall_tablet.sh
```

---

### 5. Fix 4: Battery & Native S0ix Sleep Optimization

Applies kernel-level and power management optimizations tuned for the Google Volteer / Eldrid platform, achieving extended battery life and eliminating suspend battery drain.

#### Step 4.1: Installation
```bash
sudo ./scripts/install/optimize_battery.sh
```

#### Step 4.2: What Gets Optimized

| Setting | Stock Linux | Optimized (Eldrid Profile) | Benefit |
|---|---|---|---|
| **Sleep Mode** | `deep` (ACPI S3) / broken | **`s2idle` (Native S0ix)** | **Dramatically cuts sleep drain from ~1.9W to ~0.4W (>80% reduction)** |
| **TuneD Profile** | `balanced` | `balanced-battery` | Dynamic P-state scaling and power-aware governor |
| **Intel HWP EPP** | `balance_performance` | `power` | Reduces active CPU package draw by ~1–2W |
| **PCIe ASPM** | `default` | `powersupersave` | Forces L1.1/L1.2 sub-states (~0.5W saving) |
| **USB Autosuspend** | disabled / inconsistent | `2s` delay via udev | Suspends idle USB host controllers |
| **Disk Writeback** | `15s` | `60s` | Groups dirty page flushes, saving CPU wakeups |
| **NMI Watchdog** | enabled (`1`) | disabled (`0`) | Eliminates periodic non-maskable interrupts |

> [!IMPORTANT]
> **Why S0ix (`s2idle`) instead of S3 (`deep`):** Google Volteer Chromebooks lack hardware ACPI S3 power sequencers. Forcing `mem_sleep_default=deep` leaves secondary power rails energized, causing continuous battery discharge of **~1.9W (~165 mAh/h or ~4.2%/h)**. Enforcing native `s2idle` allows the Intel Tiger Lake SoC and ChromeOS EC to assert `SLP_S0#`, entering genuine low-power idle states that reduce suspend draw to **~0.4W (~33-40 mAh/h or ~0.8%/h)** with rapid resume (~0.4s).

#### Step 4.3: Battery Longevity (80% Charge Limit)
Limit maximum charge capacity to 80% to prevent continuous high-voltage chemical stress on the lithium cells:
```bash
echo 80 | sudo tee /sys/class/power_supply/BAT0/charge_control_end_threshold
```

#### Step 4.4: Run Diagnostic Checker & Verify Status
```bash
# Run automated battery checker:
sudo ./scripts/checkers/check_battery.sh

# Or verify manually:
cat /sys/power/mem_sleep
tuned-adm active
cat /sys/devices/system/cpu/cpu0/cpufreq/energy_performance_preference
cat /sys/module/pcie_aspm/parameters/policy
cat /sys/class/power_supply/BAT0/charge_control_end_threshold
sudo powertop
```

#### Step 4.5: Uninstallation
```bash
sudo ./scripts/uninstall/uninstall_battery.sh
```

---

### 6. Fix 5: ChromeOS Fingerprint Sensor & Zero-Lag Unlock

Configures dual authentication (password OR fingerprint) for GDM / GNOME Shell, removes artificial GDM queue latency, and installs post-resume FPMCU recovery hooks.

#### Step 5.1: Build Companion Daemon (Rust-FP)
```bash
sudo dnf install -y git cargo gcc pam-devel
git clone https://github.com/CarrsterX/Rust-FP-Eldrid.git
cd Rust-FP-Eldrid
cargo build --release
sudo ./install_fingerprint.sh
cd ..
```

#### Step 5.2: Configure GDM Dual Auth & Zero-Lag Unlock
```bash
sudo ./scripts/install/install_fingerprint.sh
```

#### Step 5.3: Enroll Fingerprint Template (As Normal User, WITHOUT Sudo)
```bash
rust-fp add index
```
*Follow on-screen instructions, placing and lifting your finger on the sensor until 100% complete.*

#### Step 5.4: Run Diagnostic Checker & Test Authentication
```bash
# Run automated fingerprint checker:
sudo ./scripts/checkers/check_fingerprint.sh

# Test authentication:
sudo -k && sudo whoami
# Test GNOME Lock Screen: Super + L
```

#### Step 5.5: Uninstallation
```bash
sudo ./scripts/uninstall/uninstall_fingerprint.sh
```

---

## 🔍 Deep-Dive Technical Root Causes & Solutions

<details>
<summary><b>1. Goodix Touchscreen: ACPI Timing Race Condition vs. GPIO Userspace Solution</b></summary>

- **ACPI Device Path:** `\_SB_.PCI0.I2C1.H014` (`GDIX0000`, `PNP0C50` on bus `i2c-1` address `0x14`).
- **GPIO Lines:** Intel Tiger Lake PCH `gpiochip0`:
  - Pin 72 (`0x48`): `enable-gpios` (VDD Rail, active-high).
  - Pin 266 (`0x10A`): `reset-gpios` (Hardware Reset, active-low).
- **Failure Analysis:** Coreboot AML executes `Sleep(30ms)` asynchronously during `_ON`. The Linux driver `i2c_hid_acpi` probes before the Goodix controller initializes, failing with `-121` (`EREMOTEIO`).
- **Solution:** A userspace systemd unit executes `fix-touchscreen.sh` directly asserting Pin 72, holding Reset low for 50ms, releasing Reset to 3.3V, waiting a conservative 400ms margin, and binding `i2c_hid_acpi` explicitly.
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

<details>
<summary><b>4. Why ACPI S3 (Deep) Fails on Volteer and Drains ~1.9W in Sleep</b></summary>

- Chromebook hardware designed around Google Volteer / Tiger Lake uses Modern Standby (S0ix) as the primary low-power architecture.
- In legacy ACPI S3 (`deep`), the operating system expects firmware-directed hardware power plane shutoffs. Because the coreboot/Submarine firmware and Nuvoton EC lack S3 sequencers, secondary power rails remain energized.
- Suspend in S3 burns **~1.9W (~165 mAh/h)**. Switching to native `s2idle` allows the Intel PMC to assert `SLP_S0#`, shutting down the primary and secondary VR rails and dropping consumption to **~0.4W (~33-40 mAh/h)** with resume latency under 0.5 seconds.
</details>

<details>
<summary><b>5. GDM 2000ms Artificial Auth Latency Elimination</b></summary>

- When PAM modules (such as `librust_fp_pam_module.so`) emit informative strings like `"Place finger on reader"`, GNOME Shell's `userVerifier.js` sets a fallback queue timer of `2000ms` per message.
- Exporting `GDM_MESSAGE_TIME_MULTIPLIER=0.05` across `/etc/environment`, `/etc/security/pam_env.conf`, and systemd user manager configs scales this down to **100ms**, yielding instantaneous biometric unlock.
</details>

<details>
<summary><b>6. CrOS EC Charging Control & Thresholds</b></summary>

- Handled by the upstream `cros_charge_control` driver communicating with the Nuvoton EC over the LPC/eSPI bus.
- Setting `charge_control_end_threshold = 80` commands the EC to enter hardware AC bypass (pass-through mode), preventing continuous floating charge stress on the lithium cells.
</details>

---

## 👥 Acknowledgements & Credits

This project builds upon the valuable work of open-source projects and community developers:

- **[rvaiya/keyd](https://github.com/rvaiya/keyd)**: Author of `keyd`, the high-performance kernel-level uinput remapping daemon used for keyboard layer management.
- **[WeirdTreeThing/cros-keyboard-map](https://github.com/WeirdTreeThing/cros-keyboard-map)** & **[Chrultrabook](https://chrultrabook.com/)**: Pioneering documentation and scancode tables for Chromebook top-row keyboards under Linux.
- **[ChocolateLoverRaj/rust-fp](https://github.com/ChocolateLoverRaj/rust-fp)** & **[yuexiaoyong-star/rust-fp](https://github.com/yuexiaoyong-star/rust-fp)**: Foundational architecture for communicating with the ChromeOS FPMCU over D-Bus/PAM, forming the base of our [Rust-FP-Eldrid](https://github.com/CarrsterX/Rust-FP-Eldrid) companion project.

---

## 📜 License

Distributed under the [GNU General Public License v3.0](LICENSE).
