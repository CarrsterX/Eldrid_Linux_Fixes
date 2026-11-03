#!/usr/bin/env python3
"""
cros_tablet_daemon.py
Demonio de detección de modo tablet y ahorro de energía para HP Chromebook x360 14c (Eldrid / Volteer).

Funciones principales:
1. Monitoreo dual del estado tablet:
   - Primario: Switch físico ACPI GOOG0006 (/dev/input/by-path/*GOOG0006* o "Tablet Mode Switch")
     mediante select() sobre evdev con lectura inmediata de eventos EV_SW / SW_TABLET_MODE.
   - Secundario / Fallback: Sensor de ángulo de la bisagra IIO (cros-ec-lid-angle / in_angl_raw),
     con filtro anti-ruido (ignora transitorios 500 = LID_ANGLE_UNRELIABLE sin resetear debouncer).
2. Apagado automático de retroiluminación en Modo Tablet:
   - Al entrar en modo tablet: apaga /sys/class/leds/chromeos::kbd_backlight/brightness (0)
     recordando el brillo previo.
   - Al salir de modo tablet: restaura automáticamente el brillo original.
3. Timeout de Inactividad de Retroiluminación (Estilo ChromeOS / Ahorro de Batería):
   - Monitorea pasivamente la actividad en el teclado (keyd virtual keyboard) y touchpad (Elan Touchpad).
   - Si no hay actividad por 30 segundos (configurable en /etc/cros_tablet_daemon.conf):
     apaga la retroiluminación del teclado (0) manteniendo el teclado 100% operativo.
   - En cuanto se presiona cualquier tecla o se toca el touchpad:
     enciende instantáneamente la retroiluminación al porcentaje que tenía guardado.
   - Si el usuario apaga manualmente la retroiluminación (0%), no se vuelve a encender sola.
4. Inhibición por hardware del touchpad:
   - Escribe 1 en /sys/class/input/input*/inhibited al entrar en tablet mode.
   - Escribe 0 al volver a modo laptop.
5. Conmutación dinámica de keymap (Keyd):
   - Al entrar en modo tablet: sustituye /etc/keyd/cros.conf por el perfil cros-tablet.profile
     (donde 267 teclas físicas incluyendo tab, backspace, enter, F1-F10 están silenciadas a noop,
     y UNICAMENTE las teclas laterales de volumen quedan activas).
   - Al volver a modo laptop: restaura el perfil cros-laptop.profile (teclado completo).
6. Registro en tiempo real sin búfer (flush=True) compatible con systemd journal.
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

        # Configuración de retroiluminación y ahorro de batería
        self.config_path = "/etc/cros_tablet_daemon.conf"
        self.idle_timeout = 30.0  # Segundos por defecto (estilo ChromeOS)
        self.load_config()

        self.user_brightness = 50
        self.is_dimmed = False
        self.last_activity_time = time.time()

        # Rutas de hardware
        self.switch_dev_path = None
        self.switch_fd = None
        self.activity_devices = []  # [(name, dev_path), ...]
        self.activity_fds = {}      # {fd: name}

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

    def load_config(self):
        """Carga la configuración de timeout desde /etc/cros_tablet_daemon.conf si existe."""
        if os.path.exists(self.config_path):
            try:
                for line in open(self.config_path):
                    line = line.strip()
                    if line.startswith("#") or not line or "=" not in line:
                        continue
                    k, v = line.split("=", 1)
                    if k.strip() == "KBD_IDLE_TIMEOUT":
                        self.idle_timeout = float(v.strip())
                        print(f"[+] Timeout de inactividad configurado a {self.idle_timeout}s desde {self.config_path}", flush=True)
            except Exception as e:
                print(f"[!] Error al leer {self.config_path}: {e}", flush=True)

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

        # 3. Buscar Touchpad interno para inhibición y monitoreo de actividad
        self.touchpad_inhibit_path = None
        self.activity_devices = []

        found_kbd = False
        for p in glob.glob("/sys/class/input/input*/name"):
            try:
                name = open(p).read().strip()
                event_dirs = glob.glob(os.path.dirname(p) + "/event*")
                if not event_dirs:
                    continue
                ev_node = f"/dev/input/{os.path.basename(event_dirs[0])}"

                # Touchpad
                inh = os.path.join(os.path.dirname(p), "inhibited")
                if "Touchpad" in name or "touchpad" in name.lower():
                    if os.path.exists(inh):
                        self.touchpad_inhibit_path = inh
                    self.activity_devices.append((name, ev_node))

                # Teclado principal (preferir keyd virtual keyboard si existe)
                elif "keyd virtual keyboard" in name:
                    self.activity_devices.append((name, ev_node))
                    found_kbd = True
                elif "AT Translated Set 2 keyboard" in name and not found_kbd:
                    self.activity_devices.append((name, ev_node))

            except Exception:
                pass

        # 4. Brillo inicial del teclado
        cur = self.get_backlight_raw()
        if cur is not None and cur > 0:
            self.user_brightness = cur

        print(f"[+] Switch hardware detectado: {self.switch_dev_path}", flush=True)
        print(f"[+] Sensor de ángulo detectado: {self.lid_angle_path}", flush=True)
        print(f"[+] Touchpad inhibit detectado: {self.touchpad_inhibit_path}", flush=True)
        print(f"[+] Dispositivos de actividad: {self.activity_devices}", flush=True)
        print(f"[+] Brillo inicial teclado: {self.user_brightness}%", flush=True)
        print(f"[+] Timeout auto-apagado teclado: {self.idle_timeout}s", flush=True)

    def open_devices(self):
        # 1. Abrir switch de modo tablet
        self.close_switch_device()
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
                print(f"[!] No se pudo abrir switch {self.switch_dev_path}: {e}", flush=True)
                self.switch_fd = None

        # 2. Abrir dispositivos de actividad (teclado y touchpad)
        self.close_activity_devices()
        for name, ev_node in self.activity_devices:
            if os.path.exists(ev_node):
                try:
                    fd = os.open(ev_node, os.O_RDONLY | os.O_NONBLOCK)
                    self.activity_fds[fd] = name
                    print(f"[+] Monitoreando actividad: {name} ({ev_node})", flush=True)
                except Exception as e:
                    print(f"[!] Error al abrir dispositivo de actividad {name} ({ev_node}): {e}", flush=True)

    def close_switch_device(self):
        if self.switch_fd is not None:
            try:
                os.close(self.switch_fd)
            except Exception:
                pass
            self.switch_fd = None

    def close_activity_devices(self):
        for fd in list(self.activity_fds.keys()):
            try:
                os.close(fd)
            except Exception:
                pass
        self.activity_fds.clear()

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
            self.open_devices()

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

    def get_backlight_raw(self):
        if not os.path.exists(self.led_path):
            return None
        try:
            with open(self.led_path, "r") as f:
                return int(f.read().strip())
        except Exception:
            return None

    def set_backlight_raw(self, val):
        if not os.path.exists(self.led_path):
            return
        try:
            with open(self.led_path, "w") as f:
                f.write(f"{int(val)}\n")
        except Exception as e:
            print(f"[!] Error al escribir brillo {val}: {e}", flush=True)

    def switch_keymap(self, in_tablet):
        target = self.tablet_profile if in_tablet else self.laptop_profile
        if not os.path.exists(target):
            print(f"[!] Perfil {target} no encontrado, omitiendo cambio de keymap", flush=True)
            return

        try:
            tmp_path = f"{self.active_config}.tmp.{os.getpid()}"
            with open(target, "r") as src, open(tmp_path, "w") as dst:
                dst.write(src.read())
            os.replace(tmp_path, self.active_config)

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
            cur = self.get_backlight_raw()
            if cur is not None and cur > 0:
                self.user_brightness = cur
            self.set_backlight_raw(0)
            self.is_dimmed = False

            print(f"    2. Inhibiendo touchpad...", flush=True)
            self.set_touchpad_inhibit(True)

            print(f"    3. Silenciando teclas del teclado (solo volumen lateral activo)...", flush=True)
            self.switch_keymap(True)
            print(f"==================================================", flush=True)
        else:
            print(f"==================================================", flush=True)
            print(f"[*] MODO LAPTOP RESTAURADO ({reason})", flush=True)
            print(f"    1. Restaurando retroiluminación del teclado a {self.user_brightness}%...", flush=True)
            self.set_backlight_raw(self.user_brightness)
            self.is_dimmed = False
            self.last_activity_time = time.time()

            print(f"    2. Reactivando touchpad...", flush=True)
            self.set_touchpad_inhibit(False)

            print(f"    3. Restaurando teclado completo...", flush=True)
            self.switch_keymap(False)
            print(f"==================================================", flush=True)

    def cleanup(self):
        print("\n[*] Finalizando demonio... Restaurando hardware.", flush=True)
        self.set_backlight_raw(self.user_brightness if self.user_brightness > 0 else 50)
        self.set_touchpad_inhibit(False)
        self.switch_keymap(False)
        self.close_switch_device()
        self.close_activity_devices()
        print("[+] Hardware y keymap restaurados.", flush=True)

    def run(self):
        self.find_devices()
        self.open_devices()

        print("[+] Demonio de modo tablet y ahorro de energía iniciado y activo.", flush=True)

        angle_init = self.read_angle()
        if angle_init is not None and angle_init >= TABLET_ENTER_ANGLE and angle_init < LID_ANGLE_UNRELIABLE:
            self.angle_switch_state = True

        combined_initial = self.hw_switch_state or self.angle_switch_state
        if combined_initial:
            self.apply_tablet_mode(True, f"Estado de inicio HW={self.hw_switch_state}, Angulo={angle_init}°")
        else:
            self.switch_keymap(False)

        while self.running:
            try:
                # Monitorear switch y actividad de entrada por select()
                watch_fds = []
                if self.switch_fd is not None:
                    watch_fds.append(self.switch_fd)
                watch_fds.extend(self.activity_fds.keys())

                readable, _, _ = select.select(watch_fds, [], [], SAMPLE_INTERVAL)

                now = time.time()
                activity_detected = False
                device_error = False

                for fd in readable:
                    if fd == self.switch_fd:
                        self.read_switch_events()
                    elif fd in self.activity_fds:
                        try:
                            while True:
                                chunk = os.read(fd, 384)
                                if not chunk:
                                    break
                                activity_detected = True
                        except BlockingIOError:
                            activity_detected = True
                        except OSError:
                            device_error = True
                            break

                if device_error:
                    self.close_activity_devices()
                    self.find_devices()
                    self.open_devices()
                    continue

                # Procesar actividad de usuario para control de retroiluminación
                if activity_detected:
                    self.last_activity_time = now
                    if self.is_dimmed and not self.is_tablet and self.user_brightness > 0:
                        self.set_backlight_raw(self.user_brightness)
                        self.is_dimmed = False
                        print(f"[+] Actividad detectada: encendiendo retroiluminación ({self.user_brightness}%)", flush=True)

                # Monitorear sensor de ángulo para modo tablet
                angle = self.read_angle()
                self.update_angle_logic(angle)

                should_be_tablet = self.hw_switch_state or self.angle_switch_state
                reason_str = f"Switch={self.hw_switch_state}, Angulo={angle}°"

                if should_be_tablet != self.is_tablet:
                    self.apply_tablet_mode(should_be_tablet, reason_str)

                # Control de timeout por inactividad (solo en modo laptop)
                if not self.is_tablet and self.idle_timeout > 0:
                    if not self.is_dimmed:
                        # Detectar si el usuario cambió el brillo manualmente (ej: Alt+F6/F7 o interfaz gráfica)
                        cur = self.get_backlight_raw()
                        if cur is not None and cur != self.user_brightness:
                            self.user_brightness = cur
                            print(f"[+] Nivel de brillo actualizado por usuario: {self.user_brightness}%", flush=True)

                        # Si superó el tiempo límite sin actividad, apagar LED para ahorrar batería
                        if self.user_brightness > 0 and (now - self.last_activity_time) >= self.idle_timeout:
                            self.set_backlight_raw(0)
                            self.is_dimmed = True
                            print(f"[-] Inactividad ({int(self.idle_timeout)}s sin uso): retroiluminación apagada para ahorrar batería", flush=True)

            except Exception as e:
                print(f"[!] Excepción en ciclo principal: {e}", flush=True)
                time.sleep(1)
                self.find_devices()
                self.open_devices()


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
