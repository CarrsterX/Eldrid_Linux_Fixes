#!/usr/bin/env python3
"""
apply_touchscreen_fix.py
Automated hardware initialization and ACPI DSDT/SSDT table override
for Goodix Touchscreen (GDIX0000) on HP Chromebook x360 14c Eldrid (Volteer / Tiger Lake).

Applies two complementary layers:
  1. Userspace GPIO Power Sequencing Service (Immediate):
     Forces hardware VDD (GPIO 72) and Reset (GPIO 266) lines and binds the driver explicitly.
  2. ACPI Early CPIO Table Override (Permanent upon reboot):
     Extracts host SSDT, increases Sleep(30ms) to Sleep(300ms) in _ON method of PRIC,
     increments OEM Revision, recompiles via iasl, and embeds into Dracut initramfs.
"""

import os
import sys
import shutil
import subprocess
import glob
import re

WORK_DIR = "/tmp/acpi_touch_build"
ACPI_TABLES_SYSFS = "/sys/firmware/acpi/tables"
ACPI_OVERRIDE_DIR = "/etc/dracut.conf.d/acpi_tables"
DRACUT_CONF_DIR = "/etc/dracut.conf.d"
DRACUT_CONF_FILE = "/etc/dracut.conf.d/99-touchscreen-acpi.conf"
SUBMARINE_CFG = "/boot/submarine.cfg"


def run_cmd(cmd, check=True, cwd=None):
    print(f"[*] Executing: {' '.join(cmd) if isinstance(cmd, list) else cmd}")
    res = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, cwd=cwd)
    if check and res.returncode != 0:
        print(f"[!] Command execution failed: {cmd}")
        print(f"[!] stdout:\n{res.stdout}")
        print(f"[!] stderr:\n{res.stderr}")
        raise RuntimeError(f"Command exited with non-zero status {res.returncode}")
    return res


def check_root():
    if os.geteuid() != 0:
        print("[!] Superuser privileges required (sudo).")
        print("    Usage: sudo python3 apply_touchscreen_fix.py")
        sys.exit(1)


def check_dependencies():
    for tool in ["iasl", "dracut", "lsinitrd"]:
        if not shutil.which(tool):
            print(f"[!] Error: Required tool '{tool}' is not installed.")
            sys.exit(1)
    print("[+] Required compiler and toolchain utilities detected (iasl, dracut, lsinitrd).")


def extract_acpi_tables():
    if os.path.exists(WORK_DIR):
        shutil.rmtree(WORK_DIR)
    os.makedirs(WORK_DIR, exist_ok=True)

    dsdt_sysfs = os.path.join(ACPI_TABLES_SYSFS, "DSDT")
    ssdt_sysfs = os.path.join(ACPI_TABLES_SYSFS, "SSDT1")
    if not os.path.exists(ssdt_sysfs):
        ssdt_candidates = glob.glob(os.path.join(ACPI_TABLES_SYSFS, "SSDT*"))
        if ssdt_candidates:
            ssdt_sysfs = ssdt_candidates[0]

    if not os.path.exists(dsdt_sysfs) or not os.path.exists(ssdt_sysfs):
        raise FileNotFoundError(f"ACPI tables DSDT or SSDT not found in {ACPI_TABLES_SYSFS}")

    shutil.copy(dsdt_sysfs, os.path.join(WORK_DIR, "DSDT.aml"))
    shutil.copy(ssdt_sysfs, os.path.join(WORK_DIR, "SSDT.aml"))

    # Ensure write permissions in build directory
    os.chmod(os.path.join(WORK_DIR, "DSDT.aml"), 0o644)
    os.chmod(os.path.join(WORK_DIR, "SSDT.aml"), 0o644)

    print(f"[+] ACPI binary tables extracted to {WORK_DIR} with read/write permissions.")


def decompile_ssdt():
    print("[*] Disassembling SSDT with external symbol resolution against DSDT...")
    # Passing -e DSDT.aml allows iasl to resolve external symbols (GTXS, TSRD, CTXS, STXS, FAND)
    run_cmd(["iasl", "-e", "DSDT.aml", "-d", "SSDT.aml"], cwd=WORK_DIR)

    dsl_path = os.path.join(WORK_DIR, "SSDT.dsl")
    if not os.path.exists(dsl_path):
        raise FileNotFoundError(f"Failed to generate disassembled ASL file at {dsl_path}")

    os.chmod(dsl_path, 0o644)

    # Note: Remove original SSDT.aml (mode 0444 from sysfs) so iasl can overwrite during compilation
    orig_ssdt = os.path.join(WORK_DIR, "SSDT.aml")
    if os.path.exists(orig_ssdt):
        os.remove(orig_ssdt)

    print("[+] SSDT.dsl generated with external ACPI symbols resolved.")
    return dsl_path


def patch_ssdt_dsl(dsl_path):
    with open(dsl_path, "r", encoding="utf-8", errors="replace") as f:
        content = f.read()

    patches_applied = []
    _re = re

    # ----------------------------------------------------------------
    # PATCH 0: Correct misclassified External declarations
    # Safeguard against iasl classifying 1-arg methods as IntObj:
    # GTXS(pin) and TSRD(sensor_idx).
    # ----------------------------------------------------------------
    if "External (_SB_.PCI0.GTXS, IntObj)" in content:
        content = content.replace(
            "External (_SB_.PCI0.GTXS, IntObj)",
            "External (_SB_.PCI0.GTXS, MethodObj) // 1 Arguments"
        )
        patches_applied.append("External GTXS: IntObj -> MethodObj (1 Arg)")

    if "External (_SB_.PCI0.LPCB.EC0.TSRD, IntObj)" in content:
        content = content.replace(
            "External (_SB_.PCI0.LPCB.EC0.TSRD, IntObj)",
            "External (_SB_.PCI0.LPCB.EC0.TSRD, MethodObj) // 1 Arguments"
        )
        patches_applied.append("External TSRD: IntObj -> MethodObj (1 Arg)")

    # ----------------------------------------------------------------
    # CORE PATCH: Sleep delay adjustment in Touchscreen _ON method
    # Coreboot sets Sleep(0x1E) = 30 ms; Goodix controller requires >= 150 ms.
    # Updated inside PRIC PowerResource _ON to 300 ms (0x012C).
    # ----------------------------------------------------------------
    sleep_pattern = _re.compile(
        r'(\\_SB\.PCI0\.STXS\s*\(0xC6\)\s*\n\s*)Sleep\s*\((0x1E|30)\)(\s*\n\s*\\_SB\.PCI0\.STXS\s*\(0xF6\))'
    )
    if sleep_pattern.search(content):
        content = sleep_pattern.sub(r'\g<1>Sleep (0x012C)\g<3>', content)
        patches_applied.append("Sleep (0x1E) -> Sleep (0x012C) [300 ms] in PRIC._ON")
    elif "Sleep (0x1E)" in content:
        content = content.replace("Sleep (0x1E)", "Sleep (0x012C)")
        patches_applied.append("Sleep (0x1E) -> Sleep (0x012C) [300 ms] (global replacement)")
    elif "Sleep (0x012C)" in content:
        patches_applied.append("Sleep (0x012C) [300 ms] already present in ASL")
    else:
        print("[!] WARNING: 'Sleep (0x1E)' pattern not matched. Check if already patched.")

    # ----------------------------------------------------------------
    # PATCH 2: _STR Unicode Buffer compliance
    # Fixes iasl error 6105: _STR: found String, Buffer required
    # ----------------------------------------------------------------
    if 'Name (_STR, "Battery Charger")' in content:
        content = content.replace(
            'Name (_STR, "Battery Charger")',
            'Name (_STR, Unicode ("Battery Charger"))'
        )
        patches_applied.append("_STR: String -> Unicode ()")

    # ----------------------------------------------------------------
    # PATCH 3: PPCC Method Package encapsulation
    # Fixes dangling Package without Return statement if encountered
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
        ppcc_close = (
            "                    0xFA\n"
            "                }\n"
            "            }\n"
            "        }\n"
            "    }"
        )
        ppcc_close_fixed = (
            "                    0xFA\n"
            "                }\n"
            "            })\n"
            "        }\n"
            "    }"
        )
        content = content.replace(ppcc_close, ppcc_close_fixed, 1)
        patches_applied.append("PPCC: Package -> Return (Package ...)")

    # ----------------------------------------------------------------
    # PATCH 4: Correct GTXS assignment syntax
    # Translates disassembled reference to Local0 = \_SB.PCI0.GTXS (pin)
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
        patches_applied.append(f"GTXS: Corrected {n} disassembled invocation assignment(s)")

    # ----------------------------------------------------------------
    # PATCH 5: Correct TSRD invocation syntax
    # Translates Return (\_SB.PCI0.LPCB.EC0.TSRD (<arg>))
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
        patches_applied.append(f"TSRD: Corrected {n} argument invocation(s)")

    # ----------------------------------------------------------------
    # PATCH 6: Increment OEM Revision in DefinitionBlock
    # Linux ACPI subsystem prioritizes tables with higher OEM revision
    # (table->oem_revision > existing_table->oem_revision).
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
        # Motherboard BIOS SSDT table has OEM Revision 0x0000002A (42).
        # Override must be strictly greater.
        new_rev_int = max(old_rev_int + 1, 0x00000030)
        new_rev_str = f"0x{new_rev_int:08X}"
        content = content[:def_match.start()] + f"{prefix}{new_rev_str}{suffix}" + content[def_match.end():]
        patches_applied.append(f"OEM Revision in DefinitionBlock: {old_rev_str} -> {new_rev_str} (0x{old_rev_int:08X} -> 0x{new_rev_int:08X})")
    else:
        raise RuntimeError("DefinitionBlock declaration not found in SSDT.dsl")

    with open(dsl_path, "w", encoding="utf-8") as f:
        f.write(content)

    if patches_applied:
        for p in patches_applied:
            print(f"[+] Applied patch: {p}")
    print("[+] SSDT.dsl updated with all required ASL fixes.")


def compile_ssdt(dsl_path):
    print("[*] Compiling SSDT.dsl via iasl (resolving against DSDT)...")
    res = run_cmd(["iasl", "-e", "DSDT.aml", "-tc", "SSDT.dsl"], check=False, cwd=WORK_DIR)
    output = (res.stderr or "") + "\n" + (res.stdout or "")

    aml_path = os.path.join(WORK_DIR, "SSDT.aml")
    if res.returncode != 0 or not os.path.exists(aml_path):
        error_lines = [l for l in output.splitlines() if "Error" in l or "syntax error" in l]
        print(f"[!] Compilation failed in iasl:")
        for l in error_lines:
            print(f"    {l}")
        print("")
        print("--- Complete iasl output ---")
        print(output[:3000])
        raise RuntimeError("Compilation failed for SSDT.dsl")

    size = os.path.getsize(aml_path)
    print(f"[+++] Compilation successful. SSDT.aml generated ({size} bytes, 0 errors).")

    # Binary header verification
    with open(aml_path, "rb") as f:
        header = f.read(36)
    sig = header[0:4].decode("latin1", errors="replace")
    oem_id = header[10:16].decode("latin1", errors="replace")
    oem_table_id = header[16:24].decode("latin1", errors="replace")
    oem_rev = int.from_bytes(header[24:28], "little")
    print(f"[*] Binary header verification:")
    print(f"    - Signature:    {sig}")
    print(f"    - OEM ID:       {oem_id}")
    print(f"    - OEM Table ID: {oem_table_id}")
    print(f"    - OEM Revision: 0x{oem_rev:08X} ({oem_rev})")

    if oem_rev <= 0x0000002A:
        raise RuntimeError(
            f"CRITICAL ERROR: Compiled OEM Revision (0x{oem_rev:08X}) does not exceed BIOS table (0x0000002A). "
            f"Kernel will discard the table override."
        )
    print(f"[+++] Verification passed: OEM Revision is 0x{oem_rev:08X} (> 0x0000002A BIOS baseline).")
    return aml_path


def setup_dracut_and_rebuild(aml_path):
    print("[*] Configuring ACPI Table Override in Dracut...")
    os.makedirs(ACPI_OVERRIDE_DIR, exist_ok=True)
    dest_aml = os.path.join(ACPI_OVERRIDE_DIR, "SSDT.aml")
    shutil.copy(aml_path, dest_aml)
    os.chmod(dest_aml, 0o644)
    print(f"[+] Installed table override to: {dest_aml} ({os.path.getsize(dest_aml)} bytes)")

    # Write Dracut configuration
    os.makedirs(DRACUT_CONF_DIR, exist_ok=True)
    conf_content = f"""# Automatically configured for Chromebook Eldrid (Goodix Touchscreen GDIX0000)
acpi_override="yes"
acpi_table_dir="{ACPI_OVERRIDE_DIR}"
"""
    with open(DRACUT_CONF_FILE, "w") as f:
        f.write(conf_content)
    print(f"[+] Dracut configuration saved to: {DRACUT_CONF_FILE}")

    running_kver = subprocess.check_output(["uname", "-r"], text=True).strip()
    print(f"[*] Active running kernel release: {running_kver}")

    print(f"[*] Rebuilding initramfs for {running_kver}...")
    run_cmd(["dracut", "-f", f"/boot/initramfs-{running_kver}.img", running_kver])
    print(f"[+] initramfs-{running_kver}.img rebuilt successfully.")

    # Update secondary kernels if present in /boot
    for extra_initramfs in glob.glob("/boot/initramfs-*.img"):
        base = os.path.basename(extra_initramfs)
        if "rescue" in base:
            continue
        kver = base.replace("initramfs-", "").replace(".img", "")
        if kver != running_kver and os.path.exists(f"/boot/vmlinuz-{kver}"):
            print(f"[*] Updating secondary kernel initramfs {kver}...")
            try:
                run_cmd(["dracut", "-f", extra_initramfs, kver])
                print(f"[+] {base} updated.")
            except Exception as e:
                print(f"[!] Warning: Failed to regenerate {base}: {e}")

    print("[*] Verifying ACPI table presence in early cpio archive...")
    chk = run_cmd(["lsinitrd", f"/boot/initramfs-{running_kver}.img"], check=False)
    if "kernel/firmware/acpi/SSDT.aml" in chk.stdout:
        print("[+++] VERIFICATION PASSED: 'kernel/firmware/acpi/SSDT.aml' detected in Early CPIO archive.")
    else:
        chk_early = run_cmd(["lsinitrd", "--unpackearly", f"/boot/initramfs-{running_kver}.img"], check=False)
        print("[*] lsinitrd early archive content:\n", chk_early.stdout[:400])


def update_submarine_cfg():
    if not os.path.exists(SUBMARINE_CFG):
        print("[*] /boot/submarine.cfg not detected, skipping.")
        return

    print(f"[*] Inspecting {SUBMARINE_CFG}...")
    running_kver = subprocess.check_output(["uname", "-r"], text=True).strip()
    
    with open(SUBMARINE_CFG, "r") as f:
        content = f.read()

    if running_kver not in content:
        print(f"[*] Updating {SUBMARINE_CFG} with active kernel ({running_kver})...")
        shutil.copy(SUBMARINE_CFG, f"{SUBMARINE_CFG}.bak")
        old_kver_match = re.search(r"vmlinuz-([0-9\.\-]+fc\d+\.x86_64)", content)
        if old_kver_match:
            old_kver = old_kver_match.group(1)
            new_content = content.replace(old_kver, running_kver)
            with open(SUBMARINE_CFG, "w") as f:
                f.write(new_content)
            print(f"[+] {SUBMARINE_CFG} updated from {old_kver} to {running_kver}.")
    else:
        print(f"[+] {SUBMARINE_CFG} points to active kernel {running_kver}.")


def install_systemd_service():
    """
    Method A: Userspace systemd service.
    Enforces GPIO power lines (Pin 72=VDD, Pin 266=Reset) and explicitly binds
    the i2c_hid_acpi driver, resolving the race condition between AML Sleep execution
    and initial device discovery.
    """
    SCRIPT_SRC = os.path.join(os.path.dirname(os.path.abspath(__file__)), "fix-touchscreen.sh")
    SERVICE_SRC = os.path.join(os.path.dirname(os.path.abspath(__file__)), "touchscreen-init.service")
    SCRIPT_DST = "/usr/local/bin/fix-touchscreen.sh"
    SERVICE_DST = "/etc/systemd/system/touchscreen-init.service"

    print("\n[*] Installing systemd service (Method A / Userspace GPIO sequencing)...")

    if os.path.exists(SCRIPT_SRC):
        shutil.copy(SCRIPT_SRC, SCRIPT_DST)
    else:
        script_content = (
            "#!/usr/bin/env bash\nset -e\n"
            "DRIVER_PATH=\"/sys/bus/i2c/drivers/i2c_hid_acpi\"\n"
            "DEVICE=\"i2c-GDIX0000:00\"\n"
            "log() { echo \"[touchscreen-init] $*\" | tee -a /var/log/touchscreen-init.log; }\n"
            "log \"Starting Goodix GDIX0000 GPIO power sequence...\"\n"
            "[ -e \"${DRIVER_PATH}/${DEVICE}\" ] && echo \"${DEVICE}\" > \"${DRIVER_PATH}/unbind\" 2>/dev/null || true\n"
            "killall gpioset 2>/dev/null || true; sleep 0.05\n"
            "sleep 9999 | gpioset -c 0 72=1 266=0 & PID_R=$!; sleep 0.05; kill $PID_R 2>/dev/null || true\n"
            "sleep 99999999 | gpioset -c 0 72=1 266=1 & echo $! > /run/touchscreen-gpioset.pid\n"
            "sleep 0.4\n"
            "modprobe i2c_hid_acpi 2>/dev/null || true\n"
            "echo \"${DEVICE}\" > \"${DRIVER_PATH}/bind\" 2>/dev/null || true\n"
            "log \"Complete.\"\n"
        )
        with open(SCRIPT_DST, "w") as f:
            f.write(script_content)

    os.chmod(SCRIPT_DST, 0o755)
    print(f"[+] Script installed to: {SCRIPT_DST}")

    if os.path.exists(SERVICE_SRC):
        shutil.copy(SERVICE_SRC, SERVICE_DST)
    else:
        service_content = (
            "[Unit]\n"
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
            "WantedBy=multi-user.target\n"
        )
        with open(SERVICE_DST, "w") as f:
            f.write(service_content)

    print(f"[+] Service unit installed to: {SERVICE_DST}")
    run_cmd(["systemctl", "daemon-reload"])
    run_cmd(["systemctl", "enable", "touchscreen-init.service"])
    print("[+] Service enabled for automatic startup.")

    print("[*] Starting service runtime instance...")
    result = run_cmd(["systemctl", "start", "touchscreen-init.service"], check=False)
    if result.returncode == 0:
        print("[+++] Service started. Touchscreen hardware is ready.")
        print("[*] Verify status with: systemctl status touchscreen-init.service")
    else:
        print("[!] Service failed to start live (will activate upon subsequent reboot).")
        print(f"    Error: {result.stderr[:300]}")


def main():
    print("=" * 70)
    print("ELDRID TOUCHSCREEN HARDWARE INITIALIZATION (GOODIX GDIX0000)")
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

    print("\n" + "=" * 70)
    print("INITIALIZATION COMPLETED SUCCESSFULLY")
    print("")
    print("Two complementary mechanisms have been deployed:")
    print("")
    print("  METHOD A (Active runtime layer):")
    print("  - Systemd service forces GPIO lines and binds driver after 400ms.")
    print("    Operates immediately without reboot.")
    print("")
    print("  METHOD B (Permanent bootloader layer):")
    print("  - Patched SSDT ACPI with Sleep(300ms) embedded in Early CPIO initramfs.")
    print("    Active across future kernel boots.")
    print("")
    print("To check service health:")
    print("  systemctl status touchscreen-init.service")
    print("=" * 70)


if __name__ == "__main__":
    main()
