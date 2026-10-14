#!/usr/bin/env python3
"""
cros_tablet_daemon.py
Tablet mode detection daemon for ChromeOS convertibles (HP Chromebook x360 14c (Eldrid) / Volteer).

Monitors the Embedded Controller hinge lid angle sensor (cros-ec-lid-angle) to:
1. Filter out EC transient sentinel values (500 = LID_ANGLE_UNRELIABLE during rapid movement).
2. Enforce sustained physical angle bounds (215 deg to 360 deg) via temporal debounce.
3. Inhibit physical touchpad input (/sys/class/input/input*/inhibited) upon entering tablet mode.
4. Turn off keyboard backlight illumination in tablet mode and restore state upon laptop transition.
5. Emit SW_TABLET_MODE events via /dev/uinput to GNOME Shell and libinput.
   (libinput silences typing on the internal keyboard while preserving side volume and power buttons).
"""

import os
import sys
import glob
import time
import signal
import struct
import fcntl

# ChromeOS Embedded Controller constant indicating unstable reading during rapid movement
LID_ANGLE_UNRELIABLE = 500

# Valid physical hinge angle thresholds (in degrees)
TABLET_ENTER_MIN_ANGLE = 215  # Must be >= 215 deg and <= 360 deg for tablet state
TABLET_ENTER_MAX_ANGLE = 360  # Maximum physical hinge rotation
TABLET_EXIT_ANGLE = 165       # Must decrease below 165 deg to restore laptop state

# Debounce confirmation counters:
# 5 consecutive ticks at 0.2s = 1.0 second continuous sustained threshold
CONFIRM_ENTER_TICKS = 5
CONFIRM_EXIT_TICKS = 4
SAMPLE_INTERVAL = 0.2

# Linux uinput ioctl definitions
UI_SET_EVBIT = 0x40045564
UI_SET_SWBIT = 0x4004556d
UI_DEV_CREATE = 0x5501
UI_DEV_DESTROY = 0x5502

EV_SYN = 0
EV_SW = 5
SYN_REPORT = 0
SW_TABLET_MODE = 1


class TabletModeDaemon:
    def __init__(self):
        self.is_tablet = False
        self.last_kbd_brightness = 100
        self.uinput_fd = None
        self.running = True
        
        self.enter_counter = 0
        self.exit_counter = 0

        # Device sysfs paths
        self.lid_angle_path = None
        self.touchpad_inhibit_path = None
        self.led_path = "/sys/class/leds/chromeos::kbd_backlight/brightness"

    def find_devices(self):
        # 1. Discover ChromeOS EC lid angle sensor
        self.lid_angle_path = None
        for p in glob.glob("/sys/bus/iio/devices/iio:device*/name"):
            try:
                if "cros-ec-lid-angle" in open(p).read():
                    raw = os.path.dirname(p) + "/in_angl_raw"
                    if os.path.exists(raw):
                        self.lid_angle_path = raw
                        break
            except Exception:
                pass

        # 2. Discover internal touchpad input node for hardware inhibition
        self.touchpad_inhibit_path = None
        for p in glob.glob("/sys/class/input/input*/name"):
            try:
                name = open(p).read().strip()
                d = os.path.dirname(p)
                inhibit_file = os.path.join(d, "inhibited")
                if "Touchpad" in name and os.path.exists(inhibit_file):
                    self.touchpad_inhibit_path = inhibit_file
            except Exception:
                pass

        print(f"[+] Hinge angle sensor path: {self.lid_angle_path}")
        print(f"[+] Touchpad inhibit path: {self.touchpad_inhibit_path}")

    def setup_uinput(self):
        try:
            fd = os.open("/dev/uinput", os.O_WRONLY | os.O_NONBLOCK)
            fcntl.ioctl(fd, UI_SET_EVBIT, EV_SW)
            fcntl.ioctl(fd, UI_SET_SWBIT, SW_TABLET_MODE)

            name = b"ChromeOS Tablet Switch Daemon"
            user_dev = struct.pack("80sHHHHi", name, 0x19, 0, 0, 1, 0)
            user_dev += b"\x00" * (1024 - len(user_dev))
            os.write(fd, user_dev)
            fcntl.ioctl(fd, UI_DEV_CREATE)
            self.uinput_fd = fd
            print("[+] Registered virtual uinput SW_TABLET_MODE device node")
        except Exception as e:
            print(f"[!] Failed to register uinput device node: {e}")
            self.uinput_fd = None

    def emit_tablet_event(self, in_tablet):
        if self.uinput_fd is not None:
            try:
                val = 1 if in_tablet else 0
                now = time.time()
                sec = int(now)
                usec = int((now - sec) * 1000000)

                # SW_TABLET_MODE switch event
                ev1 = struct.pack("qqHHi", sec, usec, EV_SW, SW_TABLET_MODE, val)
                # SYN_REPORT synchronization event
                ev2 = struct.pack("qqHHi", sec, usec, EV_SYN, SYN_REPORT, 0)
                os.write(self.uinput_fd, ev1 + ev2)
            except Exception as e:
                print(f"[!] Failed to emit uinput event: {e}")

    def set_inhibited(self, path, state):
        if path and os.path.exists(path):
            try:
                with open(path, "w") as f:
                    f.write("1\n" if state else "0\n")
            except Exception as e:
                print(f"[!] Failed to write inhibit attribute {path}: {e}")

    def set_tablet_mode(self, enable):
        if self.is_tablet == enable:
            return

        self.is_tablet = enable
        if enable:
            print("[*] Transition: Tablet Mode ENGAGED (Sustained >= 215 deg for > 1.0s)")
            # 1. Inhibit physical touchpad
            self.set_inhibited(self.touchpad_inhibit_path, True)
            
            # 2. Save state and extinguish keyboard backlight illumination
            if os.path.exists(self.led_path):
                try:
                    current_br = int(open(self.led_path).read().strip())
                    if current_br > 0:
                        self.last_kbd_brightness = current_br
                    with open(self.led_path, "w") as f:
                        f.write("0\n")
                except Exception:
                    pass
                    
            # 3. Notify GNOME / libinput via SW_TABLET_MODE event
            self.emit_tablet_event(True)

        else:
            print("[*] Transition: Laptop Mode RESTORED (Sustained <= 165 deg)")
            # 1. Un-inhibit physical touchpad
            self.set_inhibited(self.touchpad_inhibit_path, False)
            
            # 2. Restore keyboard backlight illumination level
            if os.path.exists(self.led_path):
                try:
                    with open(self.led_path, "w") as f:
                        f.write(f"{self.last_kbd_brightness}\n")
                except Exception:
                    pass
                    
            # 3. Notify GNOME / libinput of laptop orientation
            self.emit_tablet_event(False)

    def cleanup(self):
        print("\n[*] Restoring input devices and switch states...")
        self.set_inhibited(self.touchpad_inhibit_path, False)
        if os.path.exists(self.led_path):
            try:
                with open(self.led_path, "w") as f:
                    f.write(f"{self.last_kbd_brightness}\n")
            except Exception:
                pass
        self.emit_tablet_event(False)

        if self.uinput_fd is not None:
            try:
                fcntl.ioctl(self.uinput_fd, UI_DEV_DESTROY)
                os.close(self.uinput_fd)
            except Exception:
                pass
        print("[+] Hardware state cleanup complete.")

    def run(self):
        self.find_devices()
        self.setup_uinput()

        if not self.lid_angle_path:
            print("[!] Error: cros-ec-lid-angle IIO sensor path not detected.")
            return

        print("[+] Tablet daemon active with sentinel filter (LID_ANGLE_UNRELIABLE = 500).")

        while self.running:
            try:
                with open(self.lid_angle_path, "r") as f:
                    angle = int(f.read().strip())

                # Sensor filter: Discard non-physical or unreliable readings
                # ChromeOS EC returns 500 (LID_ANGLE_UNRELIABLE) on high acceleration or movement
                if angle >= LID_ANGLE_UNRELIABLE or angle < 0 or angle > 360:
                    self.enter_counter = 0
                    time.sleep(SAMPLE_INTERVAL)
                    continue

                # Tablet mode engagement threshold (sustained physical confirmation)
                if not self.is_tablet:
                    if TABLET_ENTER_MIN_ANGLE <= angle <= TABLET_ENTER_MAX_ANGLE:
                        self.enter_counter += 1
                        if self.enter_counter >= CONFIRM_ENTER_TICKS:
                            self.set_tablet_mode(True)
                            self.enter_counter = 0
                    else:
                        self.enter_counter = 0

                # Laptop mode restoration threshold (sustained confirmation)
                else:
                    if angle <= TABLET_EXIT_ANGLE:
                        self.exit_counter += 1
                        if self.exit_counter >= CONFIRM_EXIT_TICKS:
                            self.set_tablet_mode(False)
                            self.exit_counter = 0
                    else:
                        self.exit_counter = 0

            except Exception:
                time.sleep(1)
                self.find_devices()

            time.sleep(SAMPLE_INTERVAL)


def main():
    daemon = TabletModeDaemon()

    def handle_exit(signum, frame):
        daemon.running = False
        daemon.cleanup()
        sys.exit(0)

    signal.signal(signal.SIGINT, handle_exit)
    signal.signal(signal.SIGTERM, handle_exit)

    daemon.run()


if __name__ == "__main__":
    main()
