#!/usr/bin/env python3
"""
ChromeOS FPMCU to Fprint D-Bus Bridge for GNOME Shell, GDM, and KDE Plasma.
Implements net.reactivated.Fprint.Manager and net.reactivated.Fprint.Device
so that:
1. GDM / GNOME Shell enables parallel gdm-fingerprint PAM authentication.
2. GNOME Settings (gnome-control-center) and KDE System Settings can list,
   enroll, and delete fingerprints via native UI dialogs.
"""

import os
import sys
import pwd
import re
import signal
import subprocess
import threading
import time
import dbus
import dbus.service
from dbus.mainloop.glib import DBusGMainLoop
from gi.repository import GLib

DBusGMainLoop(set_as_default=True)

STANDARD_FINGERS = [
    "right-thumb",
    "right-index-finger",
    "right-middle-finger",
    "right-ring-finger",
    "right-little-finger",
    "left-thumb",
    "left-index-finger",
    "left-middle-finger",
    "left-ring-finger",
    "left-little-finger",
]

FINGER_ALIASES = {
    "indice": "right-index-finger",
    "index": "right-index-finger",
    "right-index": "right-index-finger",
    "pulgar": "right-thumb",
    "thumb": "right-thumb",
    "right-thumb": "right-thumb",
    "left-index": "left-index-finger",
    "left-thumb": "left-thumb",
}


def get_default_username():
    """Detect the active console user, fallback to SUDO_USER, USER, or carrster."""
    try:
        res = subprocess.run(["loginctl", "list-sessions"], stdout=subprocess.PIPE, text=True, timeout=1.0)
        for line in res.stdout.splitlines():
            parts = line.split()
            if len(parts) >= 5 and "seat0" in parts and parts[2] not in ("gdm", "gdm-greeter", "root"):
                return parts[2]
    except Exception:
        pass
    return os.environ.get("SUDO_USER") or os.environ.get("USER") or "carrster"


def get_enrolled_fingers(username):
    """Retrieve enrolled fingers for a user via rust-fp list."""
    if not username:
        username = get_default_username()

    try:
        pw = pwd.getpwnam(username)
    except KeyError:
        return []

    env = os.environ.copy()
    env["HOME"] = pw.pw_dir
    env["USER"] = username

    try:
        res = subprocess.run(
            ["/usr/local/bin/rust-fp", "list"],
            env=env,
            user=pw.pw_uid,
            group=pw.pw_gid,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            timeout=2.0
        )
        if res.returncode != 0:
            return []
        raw_keys = re.findall(r'"([^"]+)"', res.stdout)
    except Exception as e:
        sys.stderr.write(f"cros-fprint-bridge: error running rust-fp list: {e}\n")
        return []

    fingers = []
    for k in raw_keys:
        mapped = FINGER_ALIASES.get(k.lower(), k)
        if mapped in STANDARD_FINGERS:
            if mapped not in fingers:
                fingers.append(mapped)
        else:
            for std in STANDARD_FINGERS:
                if std not in fingers:
                    fingers.append(std)
                    break

    return fingers


class FprintDevice(dbus.service.Object):
    def __init__(self, bus):
        super().__init__(bus, '/net/reactivated/Fprint/Device/0')
        self.bus = bus
        self.claimed_user = None
        self._enroll_proc = None
        self._enroll_thread = None
        self._enroll_stop_requested = False

    @dbus.service.method('net.reactivated.Fprint.Device', in_signature='s', out_signature='as')
    def ListEnrolledFingers(self, username):
        target_user = username or self.claimed_user or get_default_username()
        fingers = get_enrolled_fingers(target_user)
        return dbus.Array([dbus.String(f) for f in fingers], signature='s')

    @dbus.service.method('net.reactivated.Fprint.Device', in_signature='s', out_signature='')
    def Claim(self, username):
        self.claimed_user = username

    @dbus.service.method('net.reactivated.Fprint.Device', in_signature='', out_signature='')
    def Release(self):
        self.EnrollStop()
        self.claimed_user = None

    @dbus.service.method('net.reactivated.Fprint.Device', in_signature='s', out_signature='')
    def VerifyStart(self, finger_name):
        pass

    @dbus.service.method('net.reactivated.Fprint.Device', in_signature='', out_signature='')
    def VerifyStop(self):
        pass

    @dbus.service.signal('net.reactivated.Fprint.Device', signature='sb')
    def EnrollStatus(self, result, done):
        pass

    @dbus.service.signal('net.reactivated.Fprint.Device', signature='sb')
    def VerifyStatus(self, result, done):
        pass

    @dbus.service.signal('net.reactivated.Fprint.Device', signature='s')
    def VerifyFingerSelected(self, finger_name):
        pass

    @dbus.service.method('net.reactivated.Fprint.Device', in_signature='s', out_signature='')
    def EnrollStart(self, finger_name):
        user = self.claimed_user or get_default_username()
        self.EnrollStop()
        self._enroll_stop_requested = False

        # FPMCU hardware limit is 5 templates
        current_enrolled = get_enrolled_fingers(user)
        if finger_name not in current_enrolled and len(current_enrolled) >= 5:
            sys.stderr.write(f"cros-fprint-bridge: maximum enrolled fingers (5) reached, rejecting {finger_name}\n")
            GLib.idle_add(self.EnrollStatus, "enroll-data-full", True)
            return

        self._enroll_thread = threading.Thread(
            target=self._run_enroll_worker,
            args=(user, finger_name),
            daemon=True
        )
        self._enroll_thread.start()

    def _run_enroll_worker(self, username, finger_name):
        try:
            pw = pwd.getpwnam(username)
        except KeyError:
            GLib.idle_add(self.EnrollStatus, "enroll-unknown-error", True)
            return

        env = os.environ.copy()
        env["HOME"] = pw.pw_dir
        env["USER"] = username

        # If finger already exists in template file, remove it first
        subprocess.run(
            ["/usr/local/bin/rust-fp", "remove", finger_name],
            env=env,
            user=pw.pw_uid,
            group=pw.pw_gid,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL
        )
        for alias, std_name in FINGER_ALIASES.items():
            if std_name == finger_name and alias != finger_name:
                subprocess.run(
                    ["/usr/local/bin/rust-fp", "remove", alias],
                    env=env,
                    user=pw.pw_uid,
                    group=pw.pw_gid,
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL
                )

        cmd = ["/usr/local/bin/rust-fp", "add", finger_name]
        try:
            self._enroll_proc = subprocess.Popen(
                cmd,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                text=True,
                bufsize=1,
                env=env,
                user=pw.pw_uid,
                group=pw.pw_gid
            )
        except Exception as e:
            sys.stderr.write(f"cros-fprint-bridge: failed to launch enroll: {e}\n")
            GLib.idle_add(self.EnrollStatus, "enroll-unknown-error", True)
            return

        for line in self._enroll_proc.stdout:
            if self._enroll_stop_requested:
                break
            line_str = line.strip()
            if not line_str:
                continue

            if "Enroll progress:" in line_str:
                # Pause rust-fp IMMEDIATELY after this capture so the FPMCU
                # cannot fire the next sample while the finger is still on
                # the sensor. This enforces distinct, multi-angle captures.
                try:
                    self._enroll_proc.send_signal(signal.SIGSTOP)
                except Exception:
                    pass

                GLib.idle_add(self.EnrollStatus, "enroll-stage-passed", False)
                # Tell GNOME to show "remove your finger" between stages.
                GLib.idle_add(self.EnrollStatus, "enroll-remove-and-retry", False)

                # Wait for user to lift and repress (2 s window).
                # During this time rust-fp is suspended, so the FPMCU will
                # not capture anything until we resume the process.
                elapsed = 0.0
                while elapsed < 2.0 and not self._enroll_stop_requested:
                    time.sleep(0.1)
                    elapsed += 0.1

                # Resume rust-fp so it can wait for the next touch event.
                try:
                    self._enroll_proc.send_signal(signal.SIGCONT)
                except Exception:
                    pass

            elif "Try again" in line_str:
                GLib.idle_add(self.EnrollStatus, "enroll-retry-scan", False)
            elif "Enroll complete" in line_str:
                GLib.idle_add(self.EnrollStatus, "enroll-completed", True)
                break

        self._enroll_proc.wait()
        self._enroll_proc = None

    @dbus.service.method('net.reactivated.Fprint.Device', in_signature='', out_signature='')
    def EnrollStop(self):
        self._enroll_stop_requested = True
        if self._enroll_proc:
            # Resume the process first in case it was paused mid-enrollment
            # (SIGSTOP during the lift-wait window). A suspended process cannot
            # be terminated until it receives SIGCONT.
            try:
                self._enroll_proc.send_signal(signal.SIGCONT)
            except Exception:
                pass
            try:
                self._enroll_proc.terminate()
                self._enroll_proc.wait(timeout=0.5)
            except Exception:
                try:
                    self._enroll_proc.kill()
                except Exception:
                    pass
            self._enroll_proc = None

    @dbus.service.method('net.reactivated.Fprint.Device', in_signature='s', out_signature='')
    def DeleteEnrolledFinger(self, finger_name):
        user = self.claimed_user or get_default_username()
        try:
            pw = pwd.getpwnam(user)
            env = os.environ.copy()
            env["HOME"] = pw.pw_dir
            env["USER"] = user
            subprocess.run(
                ["/usr/local/bin/rust-fp", "remove", finger_name],
                env=env,
                user=pw.pw_uid,
                group=pw.pw_gid,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL
            )
            for alias, std_name in FINGER_ALIASES.items():
                if std_name == finger_name and alias != finger_name:
                    subprocess.run(
                        ["/usr/local/bin/rust-fp", "remove", alias],
                        env=env,
                        user=pw.pw_uid,
                        group=pw.pw_gid,
                        stdout=subprocess.DEVNULL,
                        stderr=subprocess.DEVNULL
                    )
        except Exception as e:
            sys.stderr.write(f"cros-fprint-bridge: DeleteEnrolledFinger error: {e}\n")

    @dbus.service.method('net.reactivated.Fprint.Device', in_signature='s', out_signature='')
    def DeleteEnrolledFingers(self, username):
        target_user = username or self.claimed_user or get_default_username()
        try:
            pw = pwd.getpwnam(target_user)
            env = os.environ.copy()
            env["HOME"] = pw.pw_dir
            env["USER"] = target_user
            subprocess.run(
                ["/usr/local/bin/rust-fp", "clear"],
                env=env,
                user=pw.pw_uid,
                group=pw.pw_gid,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL
            )
        except Exception as e:
            sys.stderr.write(f"cros-fprint-bridge: DeleteEnrolledFingers error: {e}\n")

    @dbus.service.method('net.reactivated.Fprint.Device', in_signature='', out_signature='')
    def DeleteEnrolledFingers2(self):
        user = self.claimed_user or get_default_username()
        self.DeleteEnrolledFingers(user)

    @dbus.service.method(dbus.PROPERTIES_IFACE, in_signature='ss', out_signature='v')
    def Get(self, interface, prop):
        if prop == 'scan-type':
            return dbus.String('press')
        elif prop == 'name':
            return dbus.String('HP Chromebook x360 Fingerprint Sensor')
        elif prop == 'num-enroll-stages':
            return dbus.Int32(5)
        elif prop == 'finger-present':
            return dbus.Boolean(False)
        elif prop == 'finger-needed':
            return dbus.Boolean(False)
        raise dbus.exceptions.DBusException('Unknown property: ' + prop)

    @dbus.service.method(dbus.PROPERTIES_IFACE, in_signature='s', out_signature='a{sv}')
    def GetAll(self, interface):
        return {
            'scan-type': dbus.String('press'),
            'name': dbus.String('HP Chromebook x360 Fingerprint Sensor'),
            'num-enroll-stages': dbus.Int32(5),
            'finger-present': dbus.Boolean(False),
            'finger-needed': dbus.Boolean(False)
        }


class FprintManager(dbus.service.Object):
    def __init__(self, bus):
        super().__init__(bus, '/net/reactivated/Fprint/Manager')

    @dbus.service.method('net.reactivated.Fprint.Manager', in_signature='', out_signature='o')
    def GetDefaultDevice(self):
        return dbus.ObjectPath('/net/reactivated/Fprint/Device/0')

    @dbus.service.method('net.reactivated.Fprint.Manager', in_signature='', out_signature='ao')
    def GetDevices(self):
        return [dbus.ObjectPath('/net/reactivated/Fprint/Device/0')]


def main():
    try:
        bus = dbus.SystemBus()
    except Exception as e:
        sys.stderr.write(f"cros-fprint-bridge: Failed to connect to system bus: {e}\n")
        sys.exit(1)

    try:
        _name = dbus.service.BusName('net.reactivated.Fprint', bus)
    except Exception as e:
        sys.stderr.write(f"cros-fprint-bridge: Failed to claim net.reactivated.Fprint: {e}\n")
        sys.exit(1)

    _dev = FprintDevice(bus)
    _mgr = FprintManager(bus)

    loop = GLib.MainLoop()
    try:
        loop.run()
    except KeyboardInterrupt:
        pass


if __name__ == '__main__':
    main()
