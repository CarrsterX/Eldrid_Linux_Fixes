#!/usr/bin/env python3
"""
apply_touchscreen_fix.py
Solución definitiva para el Touchscreen Goodix (GDIX0000) en Chromebook Eldrid (Volteer).
Aplica un ACPI SSDT Override vía Dracut corrigiendo el retardo del método _ON a 300ms.
"""

import os
import sys
import shutil
import subprocess
import re
import glob

WORK_DIR = "/tmp/acpi_touch_build"
ACPI_TABLES_SYSFS = "/sys/firmware/acpi/tables"
DRACUT_CONF_DIR = "/etc/dracut.conf.d"
DRACUT_CONF_FILE = "/etc/dracut.conf.d/acpi_override.conf"
ACPI_OVERRIDE_DIR = "/etc/acpi_override"
SUBMARINE_CFG = "/boot/submarine.cfg"

def run_cmd(cmd, check=True, cwd=None):
    print(f"[*] Ejecutando: {' '.join(cmd) if isinstance(cmd, list) else cmd}")
    res = subprocess.run(cmd, shell=isinstance(cmd, str), cwd=cwd,
                         stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    if check and res.returncode != 0:
        print(f"[!] Error ejecutando comando: {cmd}")
        print(f"[!] stdout:\n{res.stdout}")
        print(f"[!] stderr:\n{res.stderr}")
        raise RuntimeError(f"Comando falló con código {res.returncode}")
    return res

def check_root():
    if os.geteuid() != 0:
        print("[!] Este script debe ejecutarse con privilegios de root (sudo).")
        print("    Ejemplo: sudo python3 apply_touchscreen_fix.py")
        sys.exit(1)

def check_dependencies():
    for tool in ["iasl", "dracut", "lsinitrd"]:
        if not shutil.which(tool):
            print(f"[!] Error: La herramienta obligatoria '{tool}' no está instalada.")
            sys.exit(1)
    print("[+] Herramientas necesarias detectadas (iasl, dracut, lsinitrd).")

def extract_acpi_tables():
    if os.path.exists(WORK_DIR):
        shutil.rmtree(WORK_DIR)
    os.makedirs(WORK_DIR, exist_ok=True)

    dsdt_src = os.path.join(ACPI_TABLES_SYSFS, "DSDT")
    ssdt_src = os.path.join(ACPI_TABLES_SYSFS, "SSDT")

    if not os.path.exists(dsdt_src) or not os.path.exists(ssdt_src):
        raise FileNotFoundError(f"No se encontraron DSDT o SSDT en {ACPI_TABLES_SYSFS}")

    dsdt_dst = os.path.join(WORK_DIR, "DSDT.aml")
    ssdt_dst = os.path.join(WORK_DIR, "SSDT.aml")

    shutil.copy(dsdt_src, dsdt_dst)
    shutil.copy(ssdt_src, ssdt_dst)

    # Asegurar permisos de lectura y escritura en los archivos de trabajo
    os.chmod(dsdt_dst, 0o644)
    os.chmod(ssdt_dst, 0o644)

    print(f"[+] Tablas ACPI extraídas con éxito a {WORK_DIR} con permisos de escritura.")

def decompile_ssdt():
    print("[*] Desensamblando SSDT con resolución de símbolos contra DSDT...")
    # Usar -e DSDT.aml para que iasl conozca la firma de todos los métodos externos
    # (GTXS, TSRD, CTXS, STXS, FAND, etc.) y genere sintaxis ASL válida.
    run_cmd(["iasl", "-e", "DSDT.aml", "-d", "SSDT.aml"], cwd=WORK_DIR)
    dsl_path = os.path.join(WORK_DIR, "SSDT.dsl")
    if not os.path.exists(dsl_path):
        raise FileNotFoundError(f"No se generó {dsl_path}")

    # Asegurar permisos de escritura en SSDT.dsl
    os.chmod(dsl_path, 0o644)

    # IMPORTANTE: El SSDT.aml original queda bloqueado (r--r--r-- copiado de sysfs).
    # iasl necesita escribir un SSDT.aml nuevo al compilar. Lo eliminamos ahora
    # para evitar el error 'Permission denied' en el paso de compilación.
    orig_aml = os.path.join(WORK_DIR, "SSDT.aml")
    if os.path.exists(orig_aml):
        os.remove(orig_aml)

    print("[+] SSDT.dsl generado correctamente con símbolos externos resueltos.")
    return dsl_path

def patch_ssdt_dsl(dsl_path):
    import re as _re
    with open(dsl_path, "r", encoding="utf-8", errors="ignore") as f:
        content = f.read()

    patches_applied = []

    # ----------------------------------------------------------------
    # PARCHE 0: Corregir declaraciones External erróneas
    # Sin -e DSDT en la fase de decompile (comportamiento histórico del
    # script), iasl declara como IntObj métodos que en realidad tienen
    # 1 argumento: GTXS(pin) y TSRD(sensor_idx).
    # Cuando luego compilamos con -e DSDT, iasl usa su propio External
    # resuelto y genera error 6086 "Not a control method" si el DSL dice
    # IntObj pero lo llama como función.
    # Aunque ahora decompilamos CON -e DSDT, esta corrección actúa como
    # salvaguarda por si el desensamblador aún los clasifica mal.
    # ----------------------------------------------------------------
    ext_fixes = [
        ("External (_SB_.PCI0.GTXS, IntObj)",
         "External (_SB_.PCI0.GTXS, MethodObj)    // 1 Arguments"),
        ("External (_SB_.PCI0.LPCB.EC0_.TSRD, IntObj)",
         "External (_SB_.PCI0.LPCB.EC0_.TSRD, MethodObj)    // 1 Arguments"),
    ]
    for bad, good in ext_fixes:
        if bad in content:
            content = content.replace(bad, good)
            patches_applied.append(f"External: {bad.split(',')[0].strip()} IntObj -> MethodObj")

    # ----------------------------------------------------------------
    # PARCHE PRINCIPAL: Retardo Sleep en el método _ON del Touchscreen
    # Coreboot fija Sleep (0x1E) = 30 ms; Goodix necesita ≥150 ms.
    # Cambiamos dentro de PowerResource PRIC / _ON a 300 ms (0x012C).
    # ----------------------------------------------------------------
    sleep_pattern = _re.compile(
        r'(\\_SB\.PCI0\.STXS\s*\(0xC6\)\s*\n\s*)Sleep\s*\((0x1E|30)\)(\s*\n\s*\\_SB\.PCI0\.STXS\s*\(0xF6\))'
    )
    if sleep_pattern.search(content):
        content = sleep_pattern.sub(r'\g<1>Sleep (0x012C)\g<3>', content)
        patches_applied.append("Sleep (0x1E) -> Sleep (0x012C) [300 ms] en _ON de PRIC")
    elif "Sleep (0x1E)" in content:
        content = content.replace("Sleep (0x1E)", "Sleep (0x012C)")
        patches_applied.append("Sleep (0x1E) -> Sleep (0x012C) [300 ms] (reemplazo global)")
    elif "Sleep (0x012C)" in content:
        patches_applied.append("Sleep (0x012C) [300 ms] ya presente en el DSL")
    else:
        print("[!] ADVERTENCIA: No se encontró 'Sleep (0x1E)'. ¿Ya fue parcheado?")

    # ----------------------------------------------------------------
    # PARCHE 2: _STR necesita Unicode(), no String literal
    # Error iasl 6105: _STR: found String, Buffer required
    # ----------------------------------------------------------------
    if 'Name (_STR, "Battery Charger")' in content:
        content = content.replace(
            'Name (_STR, "Battery Charger")',
            'Name (_STR, Unicode ("Battery Charger"))'
        )
        patches_applied.append("_STR: String -> Unicode ()")

    # ----------------------------------------------------------------
    # PARCHE 3: Method (PPCC) - Package suelto sin Return()
    # iasl sin -e DSDT genera un Package suelto; con -e DSDT debería
    # haber generado Return() correctamente. Si aún aparece, parchamos.
    # ----------------------------------------------------------------
    ppcc_bad = (
        "        Method (PPCC, 0, NotSerialized)\n"
        "        {\n"
        "            Package (0x03)"
    )
    if ppcc_bad in content:
        ppcc_good = (
            "        Method (PPCC, 0, NotSerialized)\n"
            "        {\n"
            "            Return (Package (0x03)"
        )
        content = content.replace(ppcc_bad, ppcc_good)
        # Cerrar el Return() añadiendo ')' antes de la última '}' del método
        ppcc_close = (
            "                    0xFA\n"
            "                }\n"
            "            }\n"
            "        }\n"
            "    }"  # cierre del Scope
        )
        ppcc_close_fixed = (
            "                    0xFA\n"
            "                }\n"
            "            })\n"
            "        }\n"
            "    }"  # cierre del Scope
        )
        content = content.replace(ppcc_close, ppcc_close_fixed, 1)
        patches_applied.append("PPCC: Package -> Return (Package ...)")

    # ----------------------------------------------------------------
    # PARCHE 4: GTXS declarado como IntObj → iasl generó:
    #   <indent>0x73 = \_SB.PCI0.GTXS /* External reference */
    #   <indent>Local0
    # La semántica real del AML es:  Local0 = \_SB.PCI0.GTXS (0x73)
    # ----------------------------------------------------------------
    gtxs_pattern = _re.compile(
        r'( +)(0x[0-9a-fA-F]+) = \\_SB\.PCI0\.GTXS /\* External reference \*/\n +Local0',
        _re.MULTILINE
    )
    def fix_gtxs(m):
        indent = m.group(1)
        arg = m.group(2)
        return f"{indent}Local0 = \\_SB.PCI0.GTXS ({arg})"
    new_content, n = gtxs_pattern.subn(fix_gtxs, content)
    if n:
        content = new_content
        patches_applied.append(f"GTXS: {n} asignación(es) mal desembladas corregidas")

    # ----------------------------------------------------------------
    # PARCHE 5: TSRD declarado como IntObj → iasl generó:
    #   Return (\_SB.PCI0.LPCB.EC0.TSRD) /* External reference */
    #   <argumento suelto: Zero / One / 0x02 / 0x03>
    # La semántica real es: Return (\_SB.PCI0.LPCB.EC0.TSRD (<argumento>))
    # ----------------------------------------------------------------
    tsrd_pattern = _re.compile(
        r'(Return \(\\_SB\.PCI0\.LPCB\.EC0\.TSRD\)) /\* External reference \*/\n +([^\n]+)',
        _re.MULTILINE
    )
    def fix_tsrd(m):
        arg = m.group(2).strip()
        return f"Return (\\_SB.PCI0.LPCB.EC0.TSRD ({arg}))"
    new_content, n = tsrd_pattern.subn(fix_tsrd, content)
    if n:
        content = new_content
        patches_applied.append(f"TSRD: {n} llamada(s) con argumento suelto corregidas")

    # ----------------------------------------------------------------
    # PARCHE 6: FAND declarado como IntObj → iasl generó:
    #   TFST [One] = \_SB.PCI0.LPCB.EC0.FAND /* External reference */
    # FAND es un campo de la región EC (FieldUnit), la asignación es
    # correcta AML; el comentario molesta pero no genera error.
    # Sólo corregir si iasl lo rechaza; en la práctica no es necesario.
    # ----------------------------------------------------------------

    # ----------------------------------------------------------------
    # PARCHE 7: Incrementar Revisión OEM en DefinitionBlock
    # El kernel da preferencia a la tabla con mayor revisión
    # (requiere table->oem_revision > existing_table->oem_revision).
    # IMPORTANTE: Reemplazar directamente en la firma DefinitionBlock
    # por índice para evitar sustituir el bloque de comentarios de cabecera.
    # ----------------------------------------------------------------
    def_match = _re.search(
        r'(DefinitionBlock\s*\("[^"]*"\s*,\s*"[^"]*"\s*,\s*\d+\s*,\s*"[^"]*"\s*,\s*"[^"]*"\s*,\s*)(0x[0-9A-Fa-f]+)(\))',
        content
    )
    if def_match:
        prefix = def_match.group(1)
        old_rev_str = def_match.group(2)
        suffix = def_match.group(3)
        old_rev_int = int(old_rev_str, 16)
        # La tabla del firmware de la BIOS tiene OEM Revision 0x0000002A (42).
        # Para que Linux acepte el override, debe ser estrictamente mayor.
        new_rev_int = max(old_rev_int + 1, 0x00000030)
        new_rev_str = f"0x{new_rev_int:08X}"
        content = content[:def_match.start()] + f"{prefix}{new_rev_str}{suffix}" + content[def_match.end():]
        patches_applied.append(f"OEM Revision en DefinitionBlock: {old_rev_str} -> {new_rev_str} (0x{old_rev_int:08X} -> 0x{new_rev_int:08X})")
    else:
        raise RuntimeError("No se encontró la declaración DefinitionBlock en SSDT.dsl")

    with open(dsl_path, "w", encoding="utf-8") as f:
        f.write(content)

    if patches_applied:
        for p in patches_applied:
            print(f"[+] Parche aplicado: {p}")
    print("[+] SSDT.dsl actualizado con todos los parches necesarios.")

def compile_ssdt(dsl_path):
    print("[*] Compilando SSDT.dsl con iasl (resolución de símbolos contra DSDT)...")
    # Usar -e DSDT.aml para resolver referencias externas que no están en el DSL.
    res = run_cmd(["iasl", "-e", "DSDT.aml", "-tc", "SSDT.dsl"], check=False, cwd=WORK_DIR)
    output = (res.stderr or "") + "\n" + (res.stdout or "")

    aml_path = os.path.join(WORK_DIR, "SSDT.aml")
    if res.returncode != 0 or not os.path.exists(aml_path):
        # Mostrar sólo las líneas de error reales (filtrar warnings/remarks)
        error_lines = [l for l in output.splitlines() if "Error" in l or "syntax error" in l]
        print(f"[!] Fallo en la compilación de iasl:")
        for l in error_lines:
            print(f"    {l}")
        print("")
        print("--- Salida completa de iasl ---")
        print(output[:3000])
        raise RuntimeError("Fallo al compilar SSDT.dsl")

    size = os.path.getsize(aml_path)
    print(f"[+++] ¡Compilación exitosa! SSDT.aml generado ({size} bytes, 0 errores).")

    # Verificación binaria obligatoria de la cabecera AML
    with open(aml_path, "rb") as f:
        header = f.read(36)
    sig = header[0:4].decode("latin1", errors="replace")
    oem_id = header[10:16].decode("latin1", errors="replace")
    oem_table_id = header[16:24].decode("latin1", errors="replace")
    oem_rev = int.from_bytes(header[24:28], "little")
    print(f"[*] Verificación de cabecera binaria:")
    print(f"    - Firma:        {sig}")
    print(f"    - OEM ID:       {oem_id}")
    print(f"    - OEM Table ID: {oem_table_id}")
    print(f"    - OEM Revision: 0x{oem_rev:08X} ({oem_rev})")

    if oem_rev <= 0x0000002A:
        raise RuntimeError(
            f"ERROR CRÍTICO: El OEM Revision compilado (0x{oem_rev:08X}) no supera el de la BIOS (0x0000002A). "
            f"El kernel rechazará la tabla sin aplicar el override."
        )
    print(f"[+++] Verificación aprobada: OEM Revision es 0x{oem_rev:08X} (> 0x0000002A de BIOS).")
    return aml_path

def setup_dracut_and_rebuild(aml_path):
    print("[*] Configurando ACPI Table Override en Dracut...")
    os.makedirs(ACPI_OVERRIDE_DIR, exist_ok=True)
    dest_aml = os.path.join(ACPI_OVERRIDE_DIR, "SSDT.aml")
    shutil.copy(aml_path, dest_aml)
    os.chmod(dest_aml, 0o644)
    print(f"[+] Tabla instalada en: {dest_aml} ({os.path.getsize(dest_aml)} bytes)")

    # Escribir configuración de dracut
    os.makedirs(DRACUT_CONF_DIR, exist_ok=True)
    conf_content = f"""# Generado automáticamente para Touchscreen Eldrid (Goodix GDIX0000)
acpi_override="yes"
acpi_table_dir="{ACPI_OVERRIDE_DIR}"
"""
    with open(DRACUT_CONF_FILE, "w") as f:
        f.write(conf_content)
    print(f"[+] Configuración creada en: {DRACUT_CONF_FILE}")

    # Obtener versión de kernel en ejecución
    running_kver = subprocess.check_output(["uname", "-r"], text=True).strip()
    print(f"[*] Kernel actual en ejecución: {running_kver}")

    # Reconstruir initramfs
    print(f"[*] Regenerando initramfs para {running_kver}...")
    run_cmd(["dracut", "-f", f"/boot/initramfs-{running_kver}.img", running_kver])
    print(f"[+] initramfs-{running_kver}.img reconstruido exitosamente.")

    # Si hay otros kernels en /boot, actualizarlos también
    for extra_initramfs in glob.glob("/boot/initramfs-*.img"):
        base = os.path.basename(extra_initramfs)
        if "rescue" in base:
            continue
        kver = base.replace("initramfs-", "").replace(".img", "")
        if kver != running_kver and os.path.exists(f"/boot/vmlinuz-{kver}"):
            print(f"[*] Actualizando también initramfs para kernel secundario {kver}...")
            try:
                run_cmd(["dracut", "-f", extra_initramfs, kver])
                print(f"[+] {base} actualizado.")
            except Exception as e:
                print(f"[!] Advertencia: no se pudo regenerar {base}: {e}")

    # Verificar presencia de la tabla en el early cpio
    print("[*] Verificando presencia de la tabla ACPI en el initramfs con lsinitrd...")
    chk = run_cmd(["lsinitrd", f"/boot/initramfs-{running_kver}.img"], check=False)
    if "kernel/firmware/acpi/SSDT.aml" in chk.stdout:
        print("[+++] ¡VERIFICACIÓN EXITOSA! 'kernel/firmware/acpi/SSDT.aml' está presente en el Early CPIO.")
    else:
        chk_early = run_cmd(["lsinitrd", "--unpackearly", f"/boot/initramfs-{running_kver}.img"], check=False)
        print("[*] Resultado de lsinitrd:\n", chk_early.stdout[:400])

def update_submarine_cfg():
    if not os.path.exists(SUBMARINE_CFG):
        print("[*] No se encontró /boot/submarine.cfg, omitiendo.")
        return

    print(f"[*] Verificando {SUBMARINE_CFG}...")
    running_kver = subprocess.check_output(["uname", "-r"], text=True).strip()
    
    with open(SUBMARINE_CFG, "r") as f:
        content = f.read()

    # Si submarine.cfg está apuntando a un kernel viejo, actualizarlo
    if running_kver not in content:
        print(f"[*] Actualizando {SUBMARINE_CFG} con el kernel actual ({running_kver})...")
        shutil.copy(SUBMARINE_CFG, f"{SUBMARINE_CFG}.bak")
        
        old_kver_match = re.search(r"vmlinuz-([0-9\.\-]+fc\d+\.x86_64)", content)
        if old_kver_match:
            old_kver = old_kver_match.group(1)
            new_content = content.replace(old_kver, running_kver)
            with open(SUBMARINE_CFG, "w") as f:
                f.write(new_content)
            print(f"[+] {SUBMARINE_CFG} actualizado de {old_kver} a {running_kver}.")
    else:
        print(f"[+] {SUBMARINE_CFG} ya incluye el kernel {running_kver}.")


def install_systemd_service():
    """
    Metodo A: servicio systemd en espacio de usuario.
    Fuerza la secuencia GPIO (72=VDD, 266=reset) y hace el bind
    del driver, evitando la race condition entre el interprete AML
    y el probe de i2c_hid_acpi.
    """
    SCRIPT_SRC = os.path.join(os.path.dirname(os.path.abspath(__file__)), "fix-touchscreen.sh")
    SERVICE_SRC = os.path.join(os.path.dirname(os.path.abspath(__file__)), "touchscreen-init.service")
    SCRIPT_DST = "/usr/local/bin/fix-touchscreen.sh"
    SERVICE_DST = "/etc/systemd/system/touchscreen-init.service"

    print("\n[*] Instalando servicio systemd (Metodo A / GPIO userspace)...")

    if os.path.exists(SCRIPT_SRC):
        shutil.copy(SCRIPT_SRC, SCRIPT_DST)
    else:
        script_content = ("#!/usr/bin/env bash\nset -e\n"
            "DRIVER_PATH=\"/sys/bus/i2c/drivers/i2c_hid_acpi\"\n"
            "DEVICE=\"i2c-GDIX0000:00\"\n"
            "log() { echo \"[touchscreen-init] $*\" | tee -a /var/log/touchscreen-init.log; }\n"
            "log \"Iniciando secuencia GPIO para Goodix GDIX0000...\"\n"
            "[ -e \"${DRIVER_PATH}/${DEVICE}\" ] && echo \"${DEVICE}\" > \"${DRIVER_PATH}/unbind\" 2>/dev/null || true\n"
            "killall gpioset 2>/dev/null || true; sleep 0.05\n"
            "sleep 9999 | gpioset -c 0 72=1 266=0 & PID_R=$!; sleep 0.05; kill $PID_R 2>/dev/null || true\n"
            "sleep 99999999 | gpioset -c 0 72=1 266=1 & echo $! > /run/touchscreen-gpioset.pid\n"
            "sleep 0.4\n"
            "modprobe i2c_hid_acpi 2>/dev/null || true\n"
            "echo \"${DEVICE}\" > \"${DRIVER_PATH}/bind\" 2>/dev/null || true\n"
            "log \"Completado.\"\n")
        with open(SCRIPT_DST, "w") as f:
            f.write(script_content)

    os.chmod(SCRIPT_DST, 0o755)
    print(f"[+] Script instalado en: {SCRIPT_DST}")

    if os.path.exists(SERVICE_SRC):
        shutil.copy(SERVICE_SRC, SERVICE_DST)
    else:
        service_content = ("[Unit]\n"
            "Description=Goodix Touchscreen GPIO Fix (Eldrid/GDIX0000)\n"
            "After=systemd-udev-settle.service\n"
            "Before=display-manager.service\n"
            "Wants=systemd-udev-settle.service\n\n"
            "[Service]\n"
            "Type=forking\n"
            "ExecStart=/usr/local/bin/fix-touchscreen.sh\n"
            "ExecStop=/bin/bash -c \'kill $(cat /run/touchscreen-gpioset.pid 2>/dev/null) 2>/dev/null || true\'\n"
            "RemainAfterExit=yes\n"
            "Restart=on-failure\n"
            "RestartSec=2s\n"
            "StartLimitIntervalSec=30s\n"
            "StartLimitBurst=5\n\n"
            "[Install]\n"
            "WantedBy=multi-user.target\n")
        with open(SERVICE_DST, "w") as f:
            f.write(service_content)

    print(f"[+] Servicio instalado en: {SERVICE_DST}")
    run_cmd(["systemctl", "daemon-reload"])
    run_cmd(["systemctl", "enable", "touchscreen-init.service"])
    print("[+] Servicio habilitado para arranque automatico.")

    print("[*] Lanzando el servicio ahora (sin necesidad de reiniciar)...")
    result = run_cmd(["systemctl", "start", "touchscreen-init.service"], check=False)
    if result.returncode == 0:
        print("[+++] Servicio iniciado. El touchscreen deberia responder en segundos.")
        print("[*] Verifica con: systemctl status touchscreen-init.service")
    else:
        print("[!] El servicio no pudo iniciarse en caliente (se activara al reiniciar).")
        print(f"    Error: {result.stderr[:300]}")


def install_suspend_hook():
    """
    Instala el hook de suspend/resume en /lib/systemd/system-sleep/.
    Cuando el sistema vuelve de la suspension, re-ejecuta la secuencia
    GPIO y re-vincula i2c_hid_acpi para reactivar el touchscreen.
    """
    HOOK_SRC = os.path.join(os.path.dirname(os.path.abspath(__file__)), "touchscreen-resume.sh")
    HOOK_DST = "/lib/systemd/system-sleep/touchscreen-resume.sh"

    print("\n[*] Instalando hook de suspend/resume para el touchscreen...")

    hook_content = """#!/usr/bin/env bash
# /lib/systemd/system-sleep/touchscreen-resume.sh
# Re-inicializa el Touchscreen Goodix GDIX0000 tras volver de la suspension.
# Invocado por systemd-sleep con: $1=pre|post, $2=suspend|hibernate|...

LOGFILE="/var/log/touchscreen-init.log"
DRIVER_PATH="/sys/bus/i2c/drivers/i2c_hid_acpi"
DEVICE="i2c-GDIX0000:00"
GPIO_CHIP="0"
PIN_VDD=72
PIN_RESET=266
PIDFILE="/run/touchscreen-gpioset.pid"

log() { echo "[touchscreen-resume] $(date '+%Y-%m-%d %H:%M:%S') $*" | tee -a "${LOGFILE}"; }

case "$1" in
    pre)
        log "PRE-SUSPEND: liberando gpioset (PID=$(cat ${PIDFILE} 2>/dev/null || echo 'N/A'))..."
        if [ -f "${PIDFILE}" ]; then
            OLD_PID=$(cat "${PIDFILE}")
            kill "${OLD_PID}" 2>/dev/null || true
            rm -f "${PIDFILE}"
        fi
        killall gpioset 2>/dev/null || true
        log "PRE-SUSPEND: listo."
        ;;

    post)
        log "POST-RESUME: re-inicializando Touchscreen Goodix GDIX0000..."

        if [ -e "${DRIVER_PATH}/${DEVICE}" ]; then
            log "Desvinculando ${DEVICE}..."
            echo "${DEVICE}" > "${DRIVER_PATH}/unbind" 2>/dev/null || true
        fi

        killall gpioset 2>/dev/null || true
        sleep 0.05

        log "Paso A: VDD=1, RESET=0 durante 50ms..."
        sleep 9999 | gpioset -c ${GPIO_CHIP} ${PIN_VDD}=1 ${PIN_RESET}=0 &
        PID_RESET=$!
        sleep 0.05
        kill $PID_RESET 2>/dev/null || true

        log "Paso B: VDD=1, RESET=1 (manteniendo pines activos)..."
        sleep 99999999 | gpioset -c ${GPIO_CHIP} ${PIN_VDD}=1 ${PIN_RESET}=1 &
        PID_HOLD=$!
        echo ${PID_HOLD} > "${PIDFILE}"

        log "Esperando 400ms para boot del firmware Goodix..."
        sleep 0.4

        modprobe i2c_hid_acpi 2>/dev/null || true
        modprobe i2c_hid 2>/dev/null || true

        log "Vinculando ${DEVICE} con i2c_hid_acpi..."
        if echo "${DEVICE}" > "${DRIVER_PATH}/bind" 2>/dev/null; then
            log "POST-RESUME: Touchscreen re-inicializado. PID gpioset: ${PID_HOLD}"
        else
            if [ -e "${DRIVER_PATH}/${DEVICE}" ]; then
                log "POST-RESUME: Dispositivo ya vinculado (OK)."
            else
                sleep 0.2
                echo "${DEVICE}" > "${DRIVER_PATH}/bind" 2>/dev/null && \\
                    log "POST-RESUME: Touchscreen OK en segundo intento." || \\
                    log "ERROR: bind fallido. Ver: journalctl -u touchscreen-init"
            fi
        fi
        ;;
esac

exit 0
"""

    if os.path.exists(HOOK_SRC):
        shutil.copy(HOOK_SRC, HOOK_DST)
    else:
        with open(HOOK_DST, "w") as f:
            f.write(hook_content)

    os.chmod(HOOK_DST, 0o755)
    print(f"[+] Hook de suspend/resume instalado en: {HOOK_DST}")
    print("[+] El touchscreen se re-inicializara automaticamente al volver de la suspension.")

def main():
    print("=" * 70)
    print("INSTALADOR DE CORRECCION TOUCHSCREEN - ELDRID (GOODIX GDIX0000)")
    print("=" * 70)

    check_root()
    check_dependencies()
    extract_acpi_tables()
    dsl_path = decompile_ssdt()
    patch_ssdt_dsl(dsl_path)
    aml_path = compile_ssdt(dsl_path)
    setup_dracut_and_rebuild(aml_path)
    update_submarine_cfg()
    install_systemd_service()
    install_suspend_hook()

    print("\n" + "=" * 70)
    print("PROCESO COMPLETADO EXITOSAMENTE!")
    print("")
    print("Se han aplicado TRES metodos complementarios:")
    print("")
    print("  METODO A (activo ya mismo):")
    print("  - Servicio systemd controla GPIO directamente y vincula el")
    print("    driver tras 400ms de espera. Sin reinicio necesario.")
    print("")
    print("  METODO B (activo desde el proximo reinicio):")
    print("  - SSDT ACPI con Sleep(300ms) inyectado en el initramfs.")
    print("")
    print("  METODO C (activo ya mismo - suspend/resume):")
    print("  - Hook en /lib/systemd/system-sleep/ re-inicializa el")
    print("    touchscreen cada vez que el sistema vuelve de la suspension.")
    print("")
    print("Para verificar el estado del servicio:")
    print("  systemctl status touchscreen-init.service")
    print("Para ver logs del resume:")
    print("  tail -f /var/log/touchscreen-init.log")
    print("=" * 70)

if __name__ == "__main__":
    main()
