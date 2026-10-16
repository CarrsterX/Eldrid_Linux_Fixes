[ids]
k:0001:0001
k:0000:0000
*

# ==============================================================================
# MODO POR DEFECTO: Teclas especiales de ChromeOS (Fila superior multimedia)
# ==============================================================================
[main]
f1 = back
f2 = forward
f3 = refresh
f4 = f11
f5 = leftmeta
f6 = brightnessdown
f7 = brightnessup
f8 = mute
f9 = volumedown
f10 = volumeup

# Tecla de bloqueo (Lock / Candado / Config) -> Bloquear pantalla de GNOME (Super + L)
f13 = M-l
f14 = M-l
sleep = M-l
coffee = M-l
config = M-l
setup = M-l
prog1 = M-l

# Atajo para alternar modo: Shift Izquierdo + Meta (Super) + Esc
[shift+meta]
esc = toggle(function_keys)

# Accesos directos convenientes manteniendo Meta (Super/Búsqueda):
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

# Alt + F6/F7 -> Brillo de teclado (Keyboard Backlight)
[alt]
backspace = delete
brightnessdown = kbdillumdown
brightnessup = kbdillumup
f6 = kbdillumdown
f7 = kbdillumup

# ==============================================================================
# MODO TECLAS DE FUNCIÓN: F1 a F10 directas (Fn Lock)
# Activado / Desactivado con: Shift Izquierdo + Meta + Esc
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

# Tecla de bloqueo también en modo Fn
f13 = M-l
f14 = M-l
sleep = M-l
coffee = M-l
config = M-l
setup = M-l
prog1 = M-l

# Mantener Meta en este modo devuelve temporalmente las acciones de ChromeOS
[function_keys+meta]
f1 = back
f2 = forward
f3 = refresh
f4 = f11
f5 = leftmeta
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

# Alt + F6/F7 también en modo de teclas de función
[function_keys+alt]
backspace = delete
brightnessdown = kbdillumdown
brightnessup = kbdillumup
f6 = kbdillumdown
f7 = kbdillumup

# Permitir desactivar el modo con el mismo atajo:
[function_keys+shift+meta]
esc = toggle(function_keys)
