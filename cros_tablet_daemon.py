#!/usr/bin/env python3
"""
cros_tablet_daemon.py
Demonio de detección de modo tablet para HP Chromebook x360 14c (Eldrid / Volteer).

Funciones principales:
1. Monitoreo dual del estado tablet:
   - Primario: Switch físico ACPI GOOG0006 (/dev/input/by-path/*GOOG0006* o "Tablet Mode Switch")
     mediante select() sobre evdev con lectura inmediata de eventos EV_SW / SW_TABLET_MODE.
   - Secundario / Fallback: Sensor de ángulo de la bisagra IIO (cros-ec-lid-angle / in_angl_raw),
     con filtro anti-ruido (ignora transitorios 500 = LID_ANGLE_UNRELIABLE sin resetear debouncer).
2. Apagado automático de retroiluminación del teclado:
   - Al entrar en modo tablet: apaga /sys/class/leds/chromeos::kbd_backlight/brightness (0)
     recordando el brillo previo.
   - Al salir de modo tablet: restaura automáticamente el brillo original.
3. Inhibición por hardware del touchpad:
   - Escribe 1 en /sys/class/input/input*/inhibited al entrar en tablet mode.
   - Escribe 0 al volver a modo laptop.
4. Conmutación dinámica de keymap (Keyd):
   - Al entrar en modo tablet: sustituye /etc/keyd/cros.conf por el perfil cros-tablet.profile
     (donde 267 teclas físicas incluyendo tab, backspace, enter, F1-F10 están silenciadas a noop,
     y UNICAMENTE las teclas laterales de volumen quedan activas).
   - Al volver a modo laptop: restaura el perfil cros-laptop.profile (teclado completo).
5. Registro en tiempo real sin búfer (flush=True) compatible con systemd journal.
"""

import os
import sys
import glob
import time
import signal
import struct
import select
import fcntl
import array
import subprocess

# Códigos de evento Linux evdev
EV_SYN = 0
EV_SW = 5
SW_TABLET_MODE = 1
SYN_REPORT = 0

# Sensor IIO
LID_ANGLE_UNRELIABLE = 500
TABLET_ENTER_ANGLE = 200
TABLET_EXIT_ANGLE = 165
SAMPLE_INTERVAL = 0.25

# ioctl EVIOCGSW(len) -> _IOR('E', 0x1b, len)
EVIOCGSW_8 = 0x8008451b


class TabletModeDaemon:
    def __init__(self):
        self.running = True
        self.is_tablet = False
        self.last_kbd_brightness = 50

        # Rutas de hardware
        self.switch_dev_path = None
        self.switch_fd = None
        self.lid_angle_path = None
        self.touchpad_inhibit_path = None
        self.led_path = "/sys/class/leds/chromeos::kbd_backlight/brightness"

        # Rutas de perfiles de keyd
        self.profiles_dir = "/etc/keyd/profiles"
        self.laptop_profile = "/etc/keyd/profiles/cros-laptop.profile"
        self.tablet_profile = "/etc/keyd/profiles/cros-tablet.profile"
        self.active_config = "/etc/keyd/cros.conf"

        # Contadores de confirmación para sensor de ángulo
        self.angle_enter_ticks = 0
        self.angle_exit_ticks = 0
        self.hw_switch_state = False
        self.angle_switch_state = False

    def find_devices(self):
        # 1. Buscar Switch Físico de Modo Tablet (GOOG0006 o 'Tablet Mode Switch')
        self.switch_dev_path = None
        by_paths = glob.glob("/dev/input/by-path/*GOOG0006*-event")
        if by_paths and os.path.exists(by_paths[0]):
            self.switch_dev_path = by_paths[0]
        else:
            for p in glob.glob("/sys/class/input/input*/name"):
                try:
                    name = open(p).read().strip()
                    if "Tablet Mode Switch" in name:
                        event_dirs = glob.glob(os.path.dirname(p) + "/event*")
                        if event_dirs:
                            ev_name = os.path.basename(event_dirs[0])
                            self.switch_dev_path = f"/dev/input/{ev_name}"
                            break
                except Exception:
                    pass

        # 2. Buscar Sensor de Ángulo IIO (cros-ec-lid-angle)
        self.lid_angle_path = None
        for p in glob.glob("/sys/bus/iio/devices/iio:device*/name"):
            try:
                if "cros-ec-lid-angle" in open(p).read():
                    raw = os.path.join(os.path.dirname(p), "in_angl_raw")
                    if os.path.exists(raw):
                        self.lid_angle_path = raw
                        break
            except Exception:
                pass

        # 3. Buscar Touchpad interno para inhibición
        self.touchpad_inhibit_path = None
        for p in glob.glob("/sys/class/input/input*/name"):
            try:
                name = open(p).read().strip()
                inh = os.path.join(os.path.dirname(p), "inhibited")
                if "Touchpad" in name and os.path.exists(inh):
                    self.touchpad_inhibit_path = inh
                    break
            except Exception:
                pass

        # 4. Guardar brillo inicial del teclado si está encendido
        if os.path.exists(self.led_path):
            try:
                cur = int(open(self.led_path).read().strip())
                if cur > 0:
                    self.last_kbd_brightness = cur
            except Exception:
                pass

        print(f"[+] Switch hardware detectado: {self.switch_dev_path}", flush=True)
        print(f"[+] Sensor de ángulo detectado: {self.lid_angle_path}", flush=True)
        print(f"[+] Touchpad inhibit detectado: {self.touchpad_inhibit_path}", flush=True)
        print(f"[+] Brillo inicial teclado: {self.last_kbd_brightness}", flush=True)

    def open_switch_device(self):
        if self.switch_fd is not None:
            try:
                os.close(self.switch_fd)
            except Exception:
                pass
            self.switch_fd = None

        if self.switch_dev_path and os.path.exists(self.switch_dev_path):
            try:
                fd = os.open(self.switch_dev_path, os.O_RDONLY | os.O_NONBLOCK)
                sw_buf = array.array("B", [0] * 8)
                fcntl.ioctl(fd, EVIOCGSW_8, sw_buf, True)
                initial_sw = bool((sw_buf[0] >> SW_TABLET_MODE) & 1)
                self.hw_switch_state = initial_sw
                self.switch_fd = fd
                print(f"[+] Switch {self.switch_dev_path} abierto (Estado inicial={initial_sw})", flush=True)
            except Exception as e:
                print(f"[!] No se pudo abrir {self.switch_dev_path}: {e}", flush=True)
                self.switch_fd = None

    def read_switch_events(self):
        if self.switch_fd is None:
            return

        try:
            EVENT_SIZE = 24
            while True:
                data = os.read(self.switch_fd, EVENT_SIZE * 8)
                if not data or len(data) < EVENT_SIZE:
                    break
                for offset in range(0, len(data) - EVENT_SIZE + 1, EVENT_SIZE):
                    chunk = data[offset : offset + EVENT_SIZE]
                    sec, usec, ev_type, ev_code, ev_val = struct.unpack("qqHHi", chunk)
                    if ev_type == EV_SW and ev_code == SW_TABLET_MODE:
                        new_state = bool(ev_val == 1)
                        if new_state != self.hw_switch_state:
                            self.hw_switch_state = new_state
                            print(f"[*] Evento hardware SW_TABLET_MODE recibido: {new_state}", flush=True)
        except BlockingIOError:
            pass
        except Exception as e:
            print(f"[!] Error leyendo switch evdev: {e}", flush=True)
            self.open_switch_device()

    def read_angle(self):
        if not self.lid_angle_path or not os.path.exists(self.lid_angle_path):
            return None
        try:
            with open(self.lid_angle_path, "r") as f:
                return int(f.read().strip())
        except Exception:
            return None

    def update_angle_logic(self, angle):
        if angle is None:
            return

        if angle >= LID_ANGLE_UNRELIABLE or angle < 0:
            return

        if not self.angle_switch_state:
            if angle >= TABLET_ENTER_ANGLE:
                self.angle_enter_ticks += 1
                if self.angle_enter_ticks >= 2:
                    self.angle_switch_state = True
                    self.angle_enter_ticks = 0
            else:
                self.angle_enter_ticks = 0
        else:
            if angle <= TABLET_EXIT_ANGLE:
                self.angle_exit_ticks += 1
                if self.angle_exit_ticks >= 2:
                    self.angle_switch_state = False
                    self.angle_exit_ticks = 0
            else:
                self.angle_exit_ticks = 0

    def set_touchpad_inhibit(self, inhibit):
        if self.touchpad_inhibit_path and os.path.exists(self.touchpad_inhibit_path):
            try:
                with open(self.touchpad_inhibit_path, "w") as f:
                    f.write("1\n" if inhibit else "0\n")
            except Exception as e:
                print(f"[!] Error al ajustar touchpad inhibit: {e}", flush=True)

    def set_backlight(self, enable):
        if not os.path.exists(self.led_path):
            return

        try:
            if enable:
                target = self.last_kbd_brightness if self.last_kbd_brightness > 0 else 50
                with open(self.led_path, "w") as f:
                    f.write(f"{target}\n")
                print(f"[+] Retroiluminación teclado RESTAURADA a nivel {target}", flush=True)
            else:
                cur = int(open(self.led_path).read().strip())
                if cur > 0:
                    self.last_kbd_brightness = cur
                with open(self.led_path, "w") as f:
                    f.write("0\n")
                print(f"[-] Retroiluminación teclado APAGADA (Modo Tablet)", flush=True)
        except Exception as e:
            print(f"[!] Error al modificar brillo de teclado: {e}", flush=True)

    def switch_keymap(self, in_tablet):
        target = self.tablet_profile if in_tablet else self.laptop_profile
        if not os.path.exists(target):
            print(f"[!] Perfil {target} no encontrado, omitiendo cambio de keymap", flush=True)
            return

        try:
            # Reemplazo atómico de /etc/keyd/cros.conf
            tmp_path = f"{self.active_config}.tmp.{os.getpid()}"
            with open(target, "r") as src, open(tmp_path, "w") as dst:
                dst.write(src.read())
            os.replace(tmp_path, self.active_config)

            # Recargar keyd
            res = subprocess.run(["/usr/local/bin/keyd", "reload"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            mode_name = "TABLET (solo teclas laterales volumen +/-)" if in_tablet else "LAPTOP (teclado completo)"
            print(f"[+] Keyd recargado con perfil: {mode_name}", flush=True)
        except Exception as e:
            print(f"[!] Error al alternar keymap: {e}", flush=True)

    def apply_tablet_mode(self, in_tablet, reason=""):
        if self.is_tablet == in_tablet:
            return

        self.is_tablet = in_tablet
        if in_tablet:
            print(f"==================================================", flush=True)
            print(f"[*] MODO TABLET ACTIVADO ({reason})", flush=True)
            print(f"    1. Apagando retroiluminación del teclado...", flush=True)
            self.set_backlight(False)
            print(f"    2. Inhibiendo touchpad...", flush=True)
            self.set_touchpad_inhibit(True)
            print(f"    3. Silenciando teclas del teclado (solo volumen lateral activo)...", flush=True)
            self.switch_keymap(True)
            print(f"==================================================", flush=True)
        else:
            print(f"==================================================", flush=True)
            print(f"[*] MODO LAPTOP RESTAURADO ({reason})", flush=True)
            print(f"    1. Restaurando retroiluminación del teclado...", flush=True)
            self.set_backlight(True)
            print(f"    2. Reactivando touchpad...", flush=True)
            self.set_touchpad_inhibit(False)
            print(f"    3. Restaurando teclado completo...", flush=True)
            self.switch_keymap(False)
            print(f"==================================================", flush=True)

    def cleanup(self):
        print("\n[*] Finalizando demonio de modo tablet... Restaurando hardware.", flush=True)
        self.set_backlight(True)
        self.set_touchpad_inhibit(False)
        self.switch_keymap(False)
        if self.switch_fd is not None:
            try:
                os.close(self.switch_fd)
            except Exception:
                pass
        print("[+] Hardware y keymap restaurados.", flush=True)

    def run(self):
        self.find_devices()
        self.open_switch_device()

        print("[+] Demonio de modo tablet iniciado y activo.", flush=True)

        # Estado inicial combinado
        angle_init = self.read_angle()
        if angle_init is not None and angle_init >= TABLET_ENTER_ANGLE and angle_init < LID_ANGLE_UNRELIABLE:
            self.angle_switch_state = True

        combined_initial = self.hw_switch_state or self.angle_switch_state
        if combined_initial:
            self.apply_tablet_mode(True, f"Estado de inicio HW={self.hw_switch_state}, Angulo={angle_init}°")
        else:
            # Asegurar perfil laptop al iniciar
            self.switch_keymap(False)

        while self.running:
            try:
                r_list = [self.switch_fd] if self.switch_fd is not None else []
                readable, _, _ = select.select(r_list, [], [], SAMPLE_INTERVAL)

                if readable and self.switch_fd in readable:
                    self.read_switch_events()

                angle = self.read_angle()
                self.update_angle_logic(angle)

                should_be_tablet = self.hw_switch_state or self.angle_switch_state
                reason_str = f"Switch={self.hw_switch_state}, Angulo={angle}°"

                if should_be_tablet != self.is_tablet:
                    self.apply_tablet_mode(should_be_tablet, reason_str)

            except Exception as e:
                print(f"[!] Excepción en ciclo principal: {e}", flush=True)
                time.sleep(1)
                self.find_devices()
                self.open_switch_device()


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
