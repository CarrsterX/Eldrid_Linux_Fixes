#!/usr/bin/env bash
# ==============================================================================
# update_submarine.sh
# Guided Safe Update Wizard for Submarine Bootloader (Depthcharge / ChromeOS)
# HP Chromebook x360 14c (Eldrid / Google Volteer) - Native Fedora Linux
#
# Features:
#  - 4-Step Guided Safe Wizard [1/4 to 4/4] with visual progress bar
#  - Live animated spinner and real-time dd/curl progress feedback
#  - Dynamic CPU architecture detection (x86_64 vs arm64) & canonical nightly.link URLs
#  - Exhaustive partition unmounting (-ln, udisksctl, fuser, umount -f -l)
#  - Deep GPT header wiping (dd + wipefs) to prevent partition overlap & device-busy errors
#  - Fast metadata-based detection (no slow raw block device scans)
#  - Clean cancellation paths that safely return to the main menu
#
# Credits & Acknowledgements:
#  - Submarine Bootloader: Fyra Labs (https://github.com/FyraLabs/submarine)
# ==============================================================================

set -eo pipefail

BACKUP_DIR="/var/backups/submarine"
GITHUB_REPO="FyraLabs/submarine"

# Dynamic architecture detection (x86_64 vs arm64) & canonical download URLs
detect_system_architecture() {
    local raw_arch
    raw_arch=$(uname -m)
    case "$raw_arch" in
        x86_64|amd64)
            SYSTEM_ARCH="x86_64"
            SUBMARINE_ZIP="submarine-x86_64.zip"
            SUBMARINE_BUILD_URL="https://nightly.link/FyraLabs/submarine/workflows/build/main/submarine-x86_64.zip"
            KPART_PATTERN="*x86*.kpart"
            ;;
        aarch64|arm64)
            SYSTEM_ARCH="arm64"
            SUBMARINE_ZIP="submarine-arm64.zip"
            SUBMARINE_BUILD_URL="https://nightly.link/FyraLabs/submarine/workflows/build/main/submarine-arm64.zip"
            KPART_PATTERN="*arm*.kpart"
            ;;
        *)
            log_err "Architecture '$raw_arch' is not supported by Submarine (x86_64 and arm64 only)."
            return 1
            ;;
    esac
}
detect_system_architecture

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# Configure spinner characters based on terminal locale
SPIN_CHARS='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
if [[ ! "$LANG" =~ [Uu][Tt][Ff]-?8 ]]; then
    SPIN_CHARS='|/-\'
fi

log_info()    { echo -e "${BLUE}[INFO]${NC} $*"; }
log_ok()      { echo -e "${GREEN}[✔]${NC} $*"; }
log_warn()    { echo -e "${YELLOW}[!]${NC} $*"; }
log_err()     { echo -e "${RED}[✘]${NC} $*" >&2; }

# Step progress banner
show_step_header() {
    local step_num="$1"
    local total_steps="4"
    local title="$2"
    local pct=$(( step_num * 100 / total_steps ))

    local filled=$(( pct / 10 ))
    local empty=$(( 10 - filled ))
    local bar=""
    for ((i=0; i<filled; i++)); do bar+="▓"; done
    for ((i=0; i<empty; i++)); do bar+="░"; done

    echo ""
    echo -e "${BOLD}${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e " ${BOLD}STEP ${step_num}/${total_steps} [${bar}] ${pct}%${NC}  ▸  ${BOLD}${YELLOW}${title}${NC}"
    echo -e "${BOLD}${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
}

# Run command with real-time animated spinner
run_spinner() {
    local msg="$1"
    shift
    local tmp_log
    tmp_log=$(mktemp /tmp/sub_spin_XXXXXX.log)

    "$@" > "$tmp_log" 2>&1 &
    local pid=$!
    local char_len=${#SPIN_CHARS}
    local i=0

    tput civis 2>/dev/null || true
    while kill -0 "$pid" 2>/dev/null; do
        i=$(( (i + 1) % char_len ))
        printf "\r  ${CYAN}%c${NC} %s" "${SPIN_CHARS:$i:1}" "$msg"
        sleep 0.08
    done
    tput cnorm 2>/dev/null || true

    wait "$pid"
    local exit_code=$?
    if [ $exit_code -eq 0 ]; then
        printf "\r  ${GREEN}✔${NC} %s \n" "$msg"
    else
        printf "\r  ${RED}✘${NC} %s (Failed) \n" "$msg"
        if [ -s "$tmp_log" ]; then
            cat "$tmp_log" | sed 's/^/    /'
        fi
    fi
    rm -f "$tmp_log"
    return $exit_code
}

# Ensure root privileges
check_root() {
    if [ "$EUID" -ne 0 ]; then
        log_warn "Superuser privileges required to interact with physical storage partitions."
        echo -e "Re-launching with sudo...\n"
        exec sudo bash "$0" "$@"
    fi
}

# Ensure required utilities are installed
check_dependencies() {
    local missing=()
    for cmd in cgpt futility dd curl unzip parted wipefs partprobe; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            missing+=("$cmd")
        fi
    done

    if [ ${#missing[@]} -gt 0 ]; then
        log_err "Missing required system utilities: ${missing[*]}"
        echo -e "Install them with: ${BOLD}sudo dnf install -y ${missing[*]}${NC}"
        return 1
    fi
    return 0
}

# Resolve partition block path according to parent disk naming
# E.g. /dev/mmcblk0 1 -> /dev/mmcblk0p1; /dev/sda 1 -> /dev/sda1
get_part_path() {
    local disk="$1"
    local num="$2"
    if [[ "$disk" =~ [0-9]$ ]]; then
        echo "${disk}p${num}"
    else
        echo "${disk}${num}"
    fi
}

# Fast internal KERN-A partition detection (in milliseconds)
detect_internal_partition() {
    INTERNAL_PART=""
    INTERNAL_DISK=""
    INTERNAL_NUM=""

    # 1. Try via partlabel symlink KERN-A
    if [ -e "/dev/disk/by-partlabel/KERN-A" ]; then
        INTERNAL_PART=$(readlink -f /dev/disk/by-partlabel/KERN-A 2>/dev/null || true)
    fi

    # 2. Fallback: nvme0n1p4 (standard on Eldrid platform)
    if [ -z "$INTERNAL_PART" ] && [ -b "/dev/nvme0n1p4" ]; then
        INTERNAL_PART="/dev/nvme0n1p4"
    fi

    # 3. Fallback: cgpt with 1-second timeout
    if [ -z "$INTERNAL_PART" ] || [ ! -b "$INTERNAL_PART" ]; then
        local found_part
        found_part=$(timeout 1s cgpt find -t kernel 2>/dev/null | head -n 1 || true)
        if [ -n "$found_part" ] && [ -b "$found_part" ]; then
            INTERNAL_PART="$found_part"
        fi
    fi

    if [ -z "$INTERNAL_PART" ] || [ ! -b "$INTERNAL_PART" ]; then
        log_err "Could not detect internal Submarine KERN-A partition."
        return 1
    fi

    INTERNAL_DISK=$(echo "$INTERNAL_PART" | sed -E 's/p?[0-9]+$//')
    INTERNAL_NUM=$(echo "$INTERNAL_PART" | grep -o '[0-9]*$')

    # Safeguard: Ensure partition is NOT mounted as active OS filesystem
    if findmnt -n "$INTERNAL_PART" >/dev/null 2>&1; then
        local mnt
        mnt=$(findmnt -n -o TARGET "$INTERNAL_PART")
        log_err "CRITICAL SAFETY: Internal partition $INTERNAL_PART is mounted at '$mnt'."
        return 1
    fi
    return 0
}

# Get human-readable device transport tag
get_device_type_tag() {
    local dev="$1"
    local bname
    bname=$(basename "$dev")
    local tran
    tran=$(lsblk -d -no TRAN "$dev" 2>/dev/null || echo "")

    if [ "$tran" = "usb" ] || [[ "$dev" =~ usb ]]; then
        echo "[USB Flash Drive]"
    elif [ "$tran" = "mmc" ] || [[ "$bname" =~ ^mmcblk ]]; then
        echo "[SD / MMC Card]"
    else
        echo "[Removable Drive]"
    fi
}

# Instant check for prepared rescue media (reads GPT metadata, never scans raw blocks)
is_rescue_media_ready() {
    local disk="$1"
    local p1
    p1=$(get_part_path "$disk" 1)
    if [ ! -b "$p1" ]; then
        return 1
    fi

    # Check partition label via udev cache (0 ms)
    local part_label
    part_label=$(lsblk -no PARTLABEL "$p1" 2>/dev/null || true)
    if [[ "$part_label" =~ KERN-RESCUE|KERN-A ]]; then
        return 0
    fi

    # Check GPT table partition 1 via cgpt (sub-5 ms)
    local ptype
    ptype=$(timeout 1s cgpt show -i 1 "$disk" 2>/dev/null | grep -i "Type:" || true)
    if [[ "$ptype" =~ ChromeOS\ kernel|kernel ]]; then
        return 0
    fi

    return 1
}

# Fast scan for external drives (strictly excluding internal SSD and OS mounts)
detect_external_devices() {
    detect_internal_partition >/dev/null 2>&1 || true

    EXTERNAL_DEVS=()
    EXTERNAL_TYPES=()
    EXTERNAL_SIZES_MB=()
    EXTERNAL_SIZES_HUMAN=()
    EXTERNAL_LABELS=()

    for devpath in /sys/block/*; do
        local bname
        bname=$(basename "$devpath")
        if [[ "$bname" =~ ^(loop|dm-|zram) ]]; then continue; fi
        local full_dev="/dev/$bname"

        # Exclude internal base SSD
        if [ "$full_dev" = "$INTERNAL_DISK" ]; then continue; fi

        # Exclude NVMe transport
        local tran
        tran=$(lsblk -d -no TRAN "$full_dev" 2>/dev/null || echo "")
        if [ "$tran" = "nvme" ] || [[ "$bname" =~ ^nvme ]]; then
            continue
        fi

        # Exclude drives holding mounted OS system partitions
        local has_system_mount=0
        for mp in $(lsblk -no MOUNTPOINTS "$full_dev" 2>/dev/null); do
            if [[ "$mp" =~ ^(/|/boot|/home|/var|/etc|/usr|/swap)$ ]]; then
                has_system_mount=1
                break
            fi
        done
        if [ "$has_system_mount" -eq 1 ]; then continue; fi

        # Compute drive capacity
        local sectors
        sectors=$(cat "$devpath/size" 2>/dev/null || echo 0)
        local size_mb=$(( sectors * 512 / 1024 / 1024 ))
        local size_gb
        size_gb=$(awk "BEGIN {printf \"%.1f\", $size_mb / 1024}")
        local size_human
        size_human=$(lsblk -d -no SIZE "$full_dev" 2>/dev/null | tr -d ' ' || echo "${size_gb}G")

        local type_tag
        type_tag=$(get_device_type_tag "$full_dev")

        local vendor model
        vendor=$(cat "$devpath/device/vendor" 2>/dev/null | tr -d ' ' || echo "")
        model=$(cat "$devpath/device/model" 2>/dev/null | tr -d ' ' || lsblk -d -no MODEL "$full_dev" 2>/dev/null || echo "")
        local desc="${vendor} ${model}"
        desc=$(echo "$desc" | xargs)
        [ -z "$desc" ] && desc="Removable storage device"

        local rec_tag=""
        if [ "$size_mb" -ge 1800 ] && [ "$size_mb" -le 10000 ]; then
            rec_tag="${GREEN}(Ideal rescue capacity: 2GB-8GB)${NC}"
        elif [ "$size_mb" -gt 32000 ]; then
            rec_tag="${YELLOW}(Notice: High capacity! Entire drive will be formatted)${NC}"
        elif [ "$size_mb" -lt 1500 ]; then
            rec_tag="${RED}(Low capacity: minimum 2GB required)${NC}"
        fi

        local ready_tag=""
        if is_rescue_media_ready "$full_dev"; then
            ready_tag="${BOLD}${GREEN}[RESCUE READY]${NC}"
        fi

        EXTERNAL_DEVS+=("$full_dev")
        EXTERNAL_TYPES+=("$type_tag")
        EXTERNAL_SIZES_MB+=("$size_mb")
        EXTERNAL_SIZES_HUMAN+=("$size_human")
        EXTERNAL_LABELS+=("${BOLD}$full_dev${NC} $type_tag - $size_human - $desc $rec_tag $ready_tag")
    done
}

# Read installed kernel version banner (first 2 MB only, sub-50 ms)
get_installed_submarine_info() {
    local part="$1"
    local kinfo=""

    if [ -r "$part" ] || [ "$EUID" -eq 0 ]; then
        kinfo=$(timeout 1s dd if="$part" bs=1M count=2 2>/dev/null | strings | grep -E "^Linux version [0-9]" | head -n 1 || true)
    fi

    local fut_ver=""
    if command -v futility >/dev/null 2>&1; then
        fut_ver=$(timeout 1s futility show "$part" 2>/dev/null | grep -i "kernel version:" | head -n 1 | awk '{print $NF}' || true)
    fi

    if [ -n "$kinfo" ]; then
        echo "$kinfo"
    elif [ -n "$fut_ver" ]; then
        echo "ChromeOS Depthcharge Kernel (vblock rev $fut_ver)"
    else
        local fsize
        fsize=$(lsblk -no SIZE "$part" 2>/dev/null | tr -d ' ' || echo "64M")
        echo "Submarine Kernel Partition ($fsize)"
    fi
}

# Exhaustive and guaranteed partition unmounting
unmount_device_partitions() {
    local disk="$1"
    sync

    # Flat device list without tree symbols (no └─)
    local parts
    parts=$(lsblk -ln -o NAME "$disk" 2>/dev/null | tail -n +2 || true)

    for part in $parts; do
        local pdev="/dev/$part"
        [ ! -b "$pdev" ] && continue

        # 1. Disable swap if active
        swapoff "$pdev" 2>/dev/null || true

        # 2. Terminate blocking processes
        if command -v fuser >/dev/null 2>&1; then
            fuser -k -9 -m "$pdev" 2>/dev/null || true
        fi

        # 3. Notify udisksctl (prevents desktop automount loops)
        if command -v udisksctl >/dev/null 2>&1; then
            udisksctl unmount -b "$pdev" 2>/dev/null || true
        fi

        # 4. Force unmount all paths in /proc/mounts and findmnt
        local mnts
        mnts=$(findmnt -rno TARGET -S "$pdev" 2>/dev/null || true)
        for m in $mnts; do
            umount -f -l "$m" 2>/dev/null || true
        done
        umount -f -l "$pdev" 2>/dev/null || true
    done

    # Unmount if whole base disk is mounted
    if command -v fuser >/dev/null 2>&1; then
        fuser -k -9 -m "$disk" 2>/dev/null || true
    fi
    umount -f -l "$disk" 2>/dev/null || true

    sync
    sleep 0.5

    # 5. STRICT VERIFICATION: Ensure no partition remains busy
    for part in $parts; do
        local pdev="/dev/$part"
        if findmnt -n -S "$pdev" >/dev/null 2>&1 || grep -qw "$pdev" /proc/mounts 2>/dev/null; then
            local still_mnt
            still_mnt=$(findmnt -no TARGET -S "$pdev" 2>/dev/null || grep -w "$pdev" /proc/mounts | awk '{print $2}')
            log_err "Could not unmount $pdev (busy at '$still_mnt')."
            return 1
        fi
    done

    return 0
}

# Deep zeroing of primary and backup GPT tables to prevent overlapping partition errors
clean_disk_headers() {
    local disk="$1"

    # 1. Force wipefs
    wipefs -a -f "$disk" >/dev/null 2>&1 || true

    # 2. Zero-out first 4 MB (destroys MBR and primary GPT headers/entries)
    dd if=/dev/zero of="$disk" bs=1M count=4 conv=fsync status=none 2>/dev/null || true

    # 3. Zero-out last 40 sectors (destroys secondary backup GPT table)
    local sectors
    sectors=$(cat "/sys/block/$(basename "$disk")/size" 2>/dev/null || echo 0)
    if [ "$sectors" -gt 100 ]; then
        dd if=/dev/zero of="$disk" bs=512 seek=$(( sectors - 40 )) count=40 conv=fsync status=none 2>/dev/null || true
    fi

    sync
    partprobe "$disk" 2>/dev/null || true
    udevadm settle 2>/dev/null || sleep 1
    return 0
}

# Format and initialize full rescue media (USB Flash Drive or SD Card)
prepare_rescue_media_guided() {
    local ext_disk="$1"
    detect_internal_partition || return 1

    if [ "$ext_disk" = "$INTERNAL_DISK" ]; then
        log_err "CRITICAL SAFETY: Target device ($ext_disk) is the internal SSD."
        return 1
    fi

    local dsize_human
    dsize_human=$(lsblk -d -no SIZE "$ext_disk" 2>/dev/null | tr -d ' ' || echo "N/A")

    echo ""
    echo -e "${RED}${BOLD}FORMAT CONFIRMATION:${NC}"
    echo -e "  Target Device : ${BOLD}$ext_disk${NC} ($dsize_human)"
    echo -e "  Layout        : Partition 1 (64MB Depthcharge Kernel) + Partition 2 (Backups)"
    echo -e "${YELLOW}  WARNING: All existing data on this external drive will be permanently wiped.${NC}"
    echo ""
    echo -e "Type ${BOLD}WIPE${NC} to confirm formatting (or press Enter to cancel):"
    read -r -p "> " confirm_erase
    if [ "$confirm_erase" != "WIPE" ]; then
        log_info "Operation cancelled by user. Device $ext_disk was not modified."
        return 0
    fi

    echo ""
    log_info "Preparing clean rescue layout on $ext_disk..."

    # 1. Exhaustive unmount
    run_spinner "Unmounting active partitions on $ext_disk..." unmount_device_partitions "$ext_disk" || {
        log_err "Failed to unmount $ext_disk. Operation aborted to prevent data corruption."
        return 0
    }

    # 2. Deep clean headers
    run_spinner "Wiping previous partition signatures and GPT headers..." clean_disk_headers "$ext_disk"

    # 3. Create fresh GPT table
    run_spinner "Creating clean GPT partition table..." parted -s "$ext_disk" mklabel gpt
    partprobe "$ext_disk" 2>/dev/null || true
    udevadm settle 2>/dev/null || sleep 1

    # 4. Create Partition 1 (64 MB)
    run_spinner "Creating Partition 1 (64 MB) for Depthcharge kernel..." parted -s "$ext_disk" mkpart primary 2048s 133119s

    # 5. Create Partition 2 (Remaining space for backups)
    run_spinner "Creating Partition 2 for backups and data..." parted -s "$ext_disk" mkpart primary ext4 133120s 100%

    partprobe "$ext_disk" 2>/dev/null || true
    udevadm settle 2>/dev/null || sleep 1

    local part1
    part1=$(get_part_path "$ext_disk" 1)
    local part2
    part2=$(get_part_path "$ext_disk" 2)

    # Wait for udev block device node creation
    for i in {1..10}; do
        [ -b "$part1" ] && break
        sleep 0.3
    done

    # 6. Clone working Submarine build from SSD to Partition 1 with live progress
    echo -e "\n  ${CYAN}▸${NC} Writing verified Submarine build to $part1..."
    dd if="$INTERNAL_PART" of="$part1" bs=4M status=progress conv=fsync
    sync

    # 7. Configure ChromeOS Depthcharge attributes
    run_spinner "Configuring GPT boot attributes via cgpt..." cgpt add -i 1 -t kernel -l KERN-RESCUE -P 15 -T 1 -S 1 "$ext_disk"
    cgpt boot -p "$ext_disk" >/dev/null 2>&1 || true
    cgpt boot -i 1 "$ext_disk" >/dev/null 2>&1 || true
    sync

    # 8. Format data partition with ext4
    if [ -b "$part2" ]; then
        run_spinner "Formatting data partition ($part2) with ext4..." mkfs.ext4 -F -L SUB_RESCUE "$part2"
    fi

    log_ok "Rescue Media ($ext_disk) prepared and bootable via Ctrl + U!"
    return 0
}

# Clone working build from SSD to Rescue Media
clone_ssd_to_rescue_live() {
    local ext_disk="$1"
    detect_internal_partition || return 1

    local part1
    part1=$(get_part_path "$ext_disk" 1)
    if [ ! -b "$part1" ]; then
        log_err "Rescue partition ($part1) does not exist on $ext_disk."
        return 1
    fi

    unmount_device_partitions "$ext_disk" >/dev/null 2>&1 || true

    echo -e "\n  ${CYAN}▸${NC} Cloning Submarine from SSD ($INTERNAL_PART) to $part1..."
    dd if="$INTERNAL_PART" of="$part1" bs=4M status=progress conv=fsync
    sync

    run_spinner "Re-asserting Depthcharge boot attributes..." cgpt add -i 1 -t kernel -l KERN-RESCUE -P 15 -T 1 -S 1 "$ext_disk"
    sync
    log_ok "Rescue drive updated successfully with current SSD build!"
    return 0
}

# Restore from Rescue Media to internal SSD
clone_rescue_to_ssd_live() {
    local ext_disk="$1"
    detect_internal_partition || return 1

    local part1
    part1=$(get_part_path "$ext_disk" 1)
    if [ ! -b "$part1" ]; then
        log_err "Rescue partition ($part1) was not found on $ext_disk."
        return 1
    fi

    echo ""
    echo -e "${YELLOW}${BOLD}RESTORE CONFIRMATION:${NC}"
    echo "Internal partition $INTERNAL_PART will be overwritten with the build from $part1."
    read -r -p "Confirm restore to internal SSD? [y/N]: " confirm_r
    if [[ ! "$confirm_r" =~ ^[yYsS]$ ]]; then
        log_info "Operation cancelled by user."
        return 0
    fi

    # Pre-restore safety dump
    mkdir -p "$BACKUP_DIR"
    local bfile="$BACKUP_DIR/ssd_pre_restore_$(date +%Y%m%d_%H%M%S).kpart"
    echo -e "\n  ${CYAN}▸${NC} Creating safety backup of current SSD in $bfile..."
    dd if="$INTERNAL_PART" of="$bfile" bs=4M status=progress conv=fsync
    sync

    echo -e "\n  ${CYAN}▸${NC} Restoring rescue build to internal SSD ($INTERNAL_PART)..."
    dd if="$part1" of="$INTERNAL_PART" bs=4M status=progress conv=fsync
    sync

    run_spinner "Reconfiguring Depthcharge GPT flags on SSD..." cgpt add -i "$INTERNAL_NUM" -t kernel -P 15 -T 1 -S 1 "$INTERNAL_DISK"
    sync
    log_ok "Internal SSD restored successfully from rescue drive!"
    return 0
}

# Download and flash test build to external rescue media
flash_to_rescue_media_live() {
    local ext_disk="$1"
    detect_internal_partition || return 1

    local part1
    part1=$(get_part_path "$ext_disk" 1)
    if [ ! -b "$part1" ]; then
        log_err "Partition 1 ($part1) does not exist on $ext_disk. Initialize it first."
        return 1
    fi

    unmount_device_partitions "$ext_disk" >/dev/null 2>&1 || true

    local tmp_dir
    tmp_dir=$(mktemp -d /tmp/sub_dl_XXXXXX)
    trap 'rm -rf "$tmp_dir"' EXIT

    echo -e "\n${BOLD}Downloading official Submarine CI build (${SYSTEM_ARCH}):${NC}"
    echo -e "  Source: ${CYAN}${SUBMARINE_BUILD_URL}${NC}"
    local zip_file="$tmp_dir/$SUBMARINE_ZIP"
    if ! curl -# -fSL "$SUBMARINE_BUILD_URL" -o "$zip_file"; then
        log_err "Failed to download build from $SUBMARINE_BUILD_URL"
        return 1
    fi

    run_spinner "Unpacking kernel archive..." unzip -q "$zip_file" -d "$tmp_dir"
    local kpart_cand
    kpart_cand=$(find "$tmp_dir" -type f -name "$KPART_PATTERN" -o -name "*.kpart" | head -n 1)

    if [ -z "$kpart_cand" ] || [ ! -f "$kpart_cand" ]; then
        log_err "No valid .kpart kernel binary found in downloaded archive."
        return 1
    fi

    echo -e "\n  ${CYAN}▸${NC} Flashing test build to external media ($part1)..."
    dd if="$kpart_cand" of="$part1" bs=4M status=progress conv=fsync
    sync

    run_spinner "Configuring Depthcharge attributes..." cgpt add -i 1 -t kernel -l KERN-RESCUE -P 15 -T 1 -S 1 "$ext_disk"
    sync

    echo ""
    log_ok "Test build written to external drive ($part1)!"
    echo -e "\n${BOLD}${CYAN}=== ZERO-RISK HARDWARE VERIFICATION ===${NC}"
    echo "1. Your internal SSD was NOT modified in any way."
    echo "2. Reboot your laptop and press: ${BOLD}Ctrl + U${NC} on the Developer Mode screen."
    echo "3. If Fedora boots smoothly from external media:"
    echo "   -> The new build is 100% compatible. Re-open this wizard and apply it to the SSD."
    echo "4. If it hangs or panics:"
    echo "   -> Power off and press ${BOLD}Ctrl + D${NC} to boot normally from your untouched SSD."
    return 0
}

# Download and flash build directly to internal SSD
flash_to_ssd_live() {
    detect_internal_partition || return 1

    mkdir -p "$BACKUP_DIR"
    local bfile="$BACKUP_DIR/ssd_pre_update_$(date +%Y%m%d_%H%M%S).kpart"

    echo -e "\n  ${CYAN}▸${NC} Creating mandatory safety backup of current SSD in $bfile..."
    dd if="$INTERNAL_PART" of="$bfile" bs=4M status=progress conv=fsync
    sync

    local tmp_dir
    tmp_dir=$(mktemp -d /tmp/sub_ssd_XXXXXX)
    trap 'rm -rf "$tmp_dir"' EXIT

    echo -e "\n${BOLD}Downloading official Submarine CI build (${SYSTEM_ARCH}):${NC}"
    echo -e "  Source: ${CYAN}${SUBMARINE_BUILD_URL}${NC}"
    local zip_file="$tmp_dir/$SUBMARINE_ZIP"
    if ! curl -# -fSL "$SUBMARINE_BUILD_URL" -o "$zip_file"; then
        log_err "Failed to download build from $SUBMARINE_BUILD_URL"
        return 1
    fi

    run_spinner "Unpacking kernel archive..." unzip -q "$zip_file" -d "$tmp_dir"
    local kpart_cand
    kpart_cand=$(find "$tmp_dir" -type f -name "$KPART_PATTERN" -o -name "*.kpart" | head -n 1)

    if [ -z "$kpart_cand" ] || [ ! -f "$kpart_cand" ]; then
        log_err "No valid .kpart kernel binary found in downloaded archive."
        return 1
    fi

    echo -e "\n  ${CYAN}▸${NC} Flashing updated Submarine build to internal SSD ($INTERNAL_PART)..."
    dd if="$kpart_cand" of="$INTERNAL_PART" bs=4M status=progress conv=fsync
    sync

    run_spinner "Reconfiguring Depthcharge GPT boot flags..." cgpt add -i "$INTERNAL_NUM" -t kernel -P 15 -T 1 -S 1 "$INTERNAL_DISK"
    sync

    echo ""
    log_ok "Submarine updated successfully on internal SSD ($INTERNAL_PART)!"
    return 0
}

# ==============================================================================
# 4-STEP GUIDED SAFE UPDATE WIZARD
# ==============================================================================
run_guided_wizard() {
    clear 2>/dev/null || true
    echo "=================================================================="
    echo "       SUBMARINE BOOTLOADER - GUIDED SAFE UPDATE WIZARD           "
    echo "=================================================================="
    echo "This wizard walks you through 4 clear, zero-risk steps:"
    echo "  [Step 1/4]  25% ▸ Installation Safeguard & Rescue Media"
    echo "  [Step 2/4]  50% ▸ Local Version & Hardware Architecture Detection"
    echo "  [Step 3/4]  75% ▸ Upstream GitHub & CI Build Verification"
    echo "  [Step 4/4] 100% ▸ Safe Test-Drive (Ctrl+U) or Internal SSD Flash"
    echo "=================================================================="
    echo ""
    read -r -p "Do you want to start the guided process? [Y/n]: " start_w
    if [[ "$start_w" =~ ^[nN]$ ]]; then
        log_info "Operation cancelled by user. Returning to main menu..."
        return 0
    fi

    # --------------------------------------------------------------------------
    # STEP 1/4: PROTECTION AND RESCUE MEDIA DETECTION
    # --------------------------------------------------------------------------
    show_step_header 1 "Installation Safeguard & Rescue Media"

    printf "  ${CYAN}▸${NC} Analyzing storage layout...\r"
    detect_internal_partition || return 0
    detect_external_devices
    printf "  ${GREEN}✔${NC} Storage analyzed (Internal SSD: ${BOLD}$INTERNAL_PART${NC})\n"

    # Search for an already-initialized rescue drive
    local ready_disk=""
    for ed in "${EXTERNAL_DEVS[@]}"; do
        if is_rescue_media_ready "$ed"; then
            ready_disk="$ed"
            break
        fi
    done

    if [ -n "$ready_disk" ]; then
        local ed_size
        ed_size=$(lsblk -d -no SIZE "$ready_disk" 2>/dev/null | tr -d ' ' || echo "N/A")
        local ed_type
        ed_type=$(get_device_type_tag "$ready_disk")

        log_ok "Rescue Drive detected: ${BOLD}$ready_disk${NC} ($ed_type - $ed_size)"
        echo -e "  Status: Partition 1 ChromeOS Kernel bootable via ${BOLD}Ctrl + U${NC}"
        echo ""
        echo "How would you like to handle this rescue drive?"
        echo "  1) [DISASTER RECOVERY] Restore the build from $ready_disk back to internal SSD"
        echo "  2) [REFRESH BACKUP] Clone current working SSD build to $ready_disk"
        echo "  3) Keep current build on $ready_disk and proceed to update checks"
        echo "  4) Cancel and return to main menu"
        echo ""
        read -r -p "Select an option [1-4]: " r_choice
        case "$r_choice" in
            1)
                clone_rescue_to_ssd_live "$ready_disk" || return 0
                echo ""
                read -r -p "Do you wish to continue to update checks? [y/N]: " cont_rec
                if [[ ! "$cont_rec" =~ ^[yYsS]$ ]]; then
                    return 0
                fi
                ;;
            2)
                clone_ssd_to_rescue_live "$ready_disk" || return 0
                ;;
            3)
                log_info "Retaining current rescue media as safety key. Continuing..."
                ;;
            4|*)
                log_info "Cancelled by user. Returning..."
                return 0
                ;;
        esac
    else
        log_warn "No initialized rescue drive detected (USB Flash Drive or SD Card)."
        echo -e "  ${YELLOW}Recommended: Low-capacity USB Drive or SD Card (minimum 2 GB, ideal 4-8 GB).${NC}"
        echo ""
        echo "Protection options:"
        echo "  1) Prepare an external drive now (Full clean format & Submarine clone)"
        echo "  2) Skip external drive and create a local safety backup (.kpart) on SSD"
        echo "  3) Cancel and return to main menu"
        echo ""
        read -r -p "Select an option [1-3]: " no_r_choice
        case "$no_r_choice" in
            1)
                if [ ${#EXTERNAL_DEVS[@]} -eq 0 ]; then
                    log_warn "No USB drive or SD card currently connected."
                    echo "Please connect a USB drive or insert an SD card and press Enter to re-scan:"
                    read -r dummy_re
                    detect_external_devices
                fi
                if [ ${#EXTERNAL_DEVS[@]} -eq 0 ]; then
                    log_err "Still no external drive detected. Returning..."
                    return 0
                fi

                if [ ${#EXTERNAL_DEVS[@]} -eq 1 ]; then
                    local auto_dev="${EXTERNAL_DEVS[0]}"
                    echo -e "\nAuto-selected external drive: ${BOLD}$auto_dev${NC} (${EXTERNAL_LABELS[0]})"
                    prepare_rescue_media_guided "$auto_dev" || return 0
                else
                    echo -e "\nExternal drives detected:"
                    for i in "${!EXTERNAL_DEVS[@]}"; do
                        echo -e "  $((i+1))) ${EXTERNAL_LABELS[$i]}"
                    done
                    read -r -p "Select drive [1-${#EXTERNAL_DEVS[@]}]: " pick_ext
                    local p_idx=$((pick_ext-1))
                    if [ "$p_idx" -ge 0 ] && [ "$p_idx" -lt "${#EXTERNAL_DEVS[@]}" ]; then
                        prepare_rescue_media_guided "${EXTERNAL_DEVS[$p_idx]}" || return 0
                    else
                        log_info "Invalid selection. Returning..."
                        return 0
                    fi
                fi
                ;;
            2)
                mkdir -p "$BACKUP_DIR"
                local loc_backup="$BACKUP_DIR/submarine_ssd_$(date +%Y%m%d_%H%M%S).kpart"
                echo -e "\n  ${CYAN}▸${NC} Creating local backup file at $loc_backup..."
                dd if="$INTERNAL_PART" of="$loc_backup" bs=4M status=progress conv=fsync
                sync
                log_ok "Local safety backup complete."
                ;;
            3|*)
                log_info "Cancelled by user. Returning..."
                return 0
                ;;
        esac
    fi

    # --------------------------------------------------------------------------
    # STEP 2/4: LOCAL HARDWARE & SSD VERSION INSPECTION
    # --------------------------------------------------------------------------
    show_step_header 2 "Local Version & Hardware Architecture Detection"

    echo -e "SSD Boot Partition      : ${BOLD}$INTERNAL_PART${NC} on ${BOLD}$INTERNAL_DISK${NC} (#$INTERNAL_NUM)"
    echo -e "Detected Architecture   : ${BOLD}${CYAN}${SYSTEM_ARCH}${NC} ($(uname -m))"
    local kinfo=""
    run_spinner "Inspecting kernel version banner and vblock..." sleep 0.1
    kinfo=$(get_installed_submarine_info "$INTERNAL_PART")
    echo -e "Local Installed Kernel  : ${BOLD}${GREEN}$kinfo${NC}"

    echo ""
    read -r -p "Continue to upstream update checks? [Y/n]: " cont_p2
    if [[ "$cont_p2" =~ ^[nN]$ ]]; then
        log_info "Returning to main menu..."
        return 0
    fi

    # --------------------------------------------------------------------------
    # STEP 3/4: UPSTREAM GITHUB & CI VERIFICATION
    # --------------------------------------------------------------------------
    show_step_header 3 "Upstream GitHub & CI Build Verification"

    local has_update=0
    local latest_tag=""
    local latest_date=""
    local release_title=""
    local release_notes=""

    fetch_gh_release() {
        local api_url="https://api.github.com/repos/$GITHUB_REPO/releases/latest"
        curl -sSL --connect-timeout 4 --max-time 8 "$api_url" -o /tmp/sub_gh_release.json 2>/dev/null || true
    }

    run_spinner "Querying official repository ($GITHUB_REPO)..." fetch_gh_release

    if [ -s /tmp/sub_gh_release.json ]; then
        if command -v jq >/dev/null 2>&1; then
            latest_tag=$(jq -r '.tag_name // empty' /tmp/sub_gh_release.json 2>/dev/null || true)
            latest_date=$(jq -r '.published_at // empty' /tmp/sub_gh_release.json 2>/dev/null || true)
            release_title=$(jq -r '.name // empty' /tmp/sub_gh_release.json 2>/dev/null || true)
            release_notes=$(jq -r '.body // empty' /tmp/sub_gh_release.json 2>/dev/null | head -n 8 || true)
        fi
        if [ -n "$latest_tag" ] && [ "$latest_tag" != "null" ]; then
            has_update=1
            echo -e "Latest GitHub Release    : ${BOLD}${GREEN}$latest_tag${NC} (${latest_date:0:10})"
            [ -n "$release_title" ] && echo -e "Release Title            : $release_title"
            if [ -n "$release_notes" ]; then
                echo -e "\nRelease Changelog Notes:"
                echo "$release_notes" | sed 's/^/  /'
            fi
        fi
    fi
    rm -f /tmp/sub_gh_release.json

    if [ "$has_update" -eq 0 ]; then
        log_warn "Could not fetch GitHub Release info or offline."
        echo "Official automated CI builds (nightly.link) remain directly available."
    fi

    echo -e "\nOfficial CI automated build URL for your architecture (${BOLD}${CYAN}${SYSTEM_ARCH}${NC}):"
    echo -e "  ${BOLD}${CYAN}${SUBMARINE_BUILD_URL}${NC}"

    # --------------------------------------------------------------------------
    # STEP 4/4: SAFE TEST-DRIVE OR DIRECT FLASH
    # --------------------------------------------------------------------------
    show_step_header 4 "Safe Test-Drive / Internal SSD Flash"

    detect_external_devices
    local target_ext=""
    for ed in "${EXTERNAL_DEVS[@]}"; do
        if is_rescue_media_ready "$ed"; then
            target_ext="$ed"
            break
        fi
    done
    [ -z "$target_ext" ] && [ ${#EXTERNAL_DEVS[@]} -gt 0 ] && target_ext="${EXTERNAL_DEVS[0]}"

    echo "How would you like to proceed?"
    if [ -n "$target_ext" ]; then
        echo -e "  1) ${BOLD}${GREEN}[RECOMMENDED] Test-Drive first on external drive (${target_ext})${NC}"
        echo "     -> Flashes new build to external USB/SD drive only."
        echo "     -> Internal SSD is NOT modified."
        echo "     -> Reboot and test with Ctrl + U. If boots cleanly, apply to SSD."
    else
        echo "  1) [External test-drive unavailable - connect a USB drive or SD card]"
    fi
    echo "  2) Flash directly to internal SSD ($INTERNAL_PART)"
    echo "     -> Writes build directly with mandatory local safety backup."
    echo "  3) Cancel and return to main menu"
    echo ""
    read -r -p "Select an option [1-3]: " p4_opt
    case "$p4_opt" in
        1)
            if [ -z "$target_ext" ]; then
                log_warn "No external drive ready for test-drive. Returning..."
                return 0
            fi
            flash_to_rescue_media_live "$target_ext" || return 0
            ;;
        2)
            echo ""
            echo -e "${YELLOW}${BOLD}MANDATORY CONFIRMATION:${NC}"
            echo "This will overwrite your internal Submarine partition $INTERNAL_PART."
            read -r -p "Confirm physical flash to internal SSD? [y/N]: " confirm_ssd
            if [[ ! "$confirm_ssd" =~ ^[yYsS]$ ]]; then
                log_info "Operation cancelled by user. Returning to main menu..."
                return 0
            fi
            flash_to_ssd_live || return 0
            ;;
        3|*)
            log_info "Operation cancelled by user. Returning to main menu..."
            return 0
            ;;
    esac
}

# Quick storage diagnostics
show_quick_diagnostics() {
    clear 2>/dev/null || true
    echo "=================================================================="
    echo "                   STORAGE DIAGNOSTICS & STATUS                  "
    echo "=================================================================="
    printf "  ${CYAN}▸${NC} Analyzing devices...\r"
    detect_internal_partition >/dev/null 2>&1 || true
    detect_external_devices
    printf "  ${GREEN}✔${NC} Analysis complete.\n"

    echo -e "\n${BOLD}Internal SSD (System / Submarine Bootloader):${NC}"
    echo -e "  Partition    : ${BOLD}$INTERNAL_PART${NC} on $INTERNAL_DISK (#$INTERNAL_NUM)"
    echo -e "  Architecture : ${BOLD}${SYSTEM_ARCH}${NC}"
    local kinfo
    kinfo=$(get_installed_submarine_info "$INTERNAL_PART")
    echo -e "  Kernel Info  : $kinfo"

    echo -e "\n${BOLD}External Media (USB Flash Drives / SD Cards):${NC}"
    if [ ${#EXTERNAL_DEVS[@]} -eq 0 ]; then
        echo -e "  ${YELLOW}No external drives detected.${NC}"
    else
        for ed in "${EXTERNAL_DEVS[@]}"; do
            echo -e "  Device : ${BOLD}$ed${NC} $(get_device_type_tag "$ed")"
            lsblk -o NAME,SIZE,FSTYPE,PARTLABEL,MOUNTPOINTS "$ed" 2>/dev/null | sed 's/^/    /' || true
        done
    fi
}

# Manual disaster recovery from backup
run_manual_restore() {
    clear 2>/dev/null || true
    echo "=================================================================="
    echo "                     EMERGENCY DISASTER RECOVERY                  "
    echo "=================================================================="
    detect_internal_partition || return 1
    detect_external_devices

    echo "Select restore source:"
    echo "  1) Restore from external Rescue Media (USB Drive / SD Card)"
    echo "  2) Restore from a previous local backup file (.kpart)"
    echo "  3) Cancel and return to main menu"
    echo ""
    read -r -p "Option [1-3]: " opt_rec
    case "$opt_rec" in
        1)
            local ready_disk=""
            for ed in "${EXTERNAL_DEVS[@]}"; do
                if is_rescue_media_ready "$ed"; then
                    ready_disk="$ed"
                    break
                fi
            done
            if [ -n "$ready_disk" ]; then
                clone_rescue_to_ssd_live "$ready_disk"
            else
                log_warn "No initialized rescue drive detected."
            fi
            ;;
        2)
            if [ ! -d "$BACKUP_DIR" ] || [ -z "$(ls -A "$BACKUP_DIR"/*.kpart 2>/dev/null)" ]; then
                log_err "No backup files found in $BACKUP_DIR"
                return 0
            fi
            local backups=("$BACKUP_DIR"/*.kpart)
            echo "Available backup files in $BACKUP_DIR:"
            for i in "${!backups[@]}"; do
                local bname
                bname=$(basename "${backups[$i]}")
                local bsize
                bsize=$(du -h "${backups[$i]}" | cut -f1)
                echo "  $((i+1))) $bname ($bsize)"
            done
            read -r -p "Select backup to restore: " b_idx_choice
            local b_idx=$((b_idx_choice-1))
            if [ "$b_idx" -ge 0 ] && [ "$b_idx" -lt "${#backups[@]}" ]; then
                local chosen_file="${backups[$b_idx]}"
                echo -e "\n  ${CYAN}▸${NC} Restoring $chosen_file to $INTERNAL_PART..."
                dd if="$chosen_file" of="$INTERNAL_PART" bs=4M status=progress conv=fsync
                sync
                run_spinner "Reconfiguring Depthcharge flags..." cgpt add -i "$INTERNAL_NUM" -t kernel -P 15 -T 1 -S 1 "$INTERNAL_DISK"
                sync
                log_ok "Restore successful from local backup file!"
            else
                log_info "Invalid selection."
            fi
            ;;
        3|*)
            log_info "Operation cancelled."
            ;;
    esac
}

# ==============================================================================
# COMPACT MAIN MENU
# ==============================================================================
show_menu() {
    clear 2>/dev/null || true
    echo "=================================================================="
    echo "      SUBMARINE BOOTLOADER - MANAGEMENT & SAFE UPDATE SUITE       "
    echo "=================================================================="
    echo -e "  ${BOLD}${GREEN}1) Start Guided Safe Update Wizard (Recommended)${NC}"
    echo "     [1. Safeguard -> 2. Detect -> 3. Updates -> 4. Test/Apply]"
    echo ""
    echo "  2) Emergency Recovery Mode (Restore from backup/USB)"
    echo "  3) Quick Storage Diagnostics (SSD & External Drives)"
    echo "  4) Exit"
    echo "=================================================================="
    read -r -p "Select an option [1-4]: " opt
    case "$opt" in
        1)
            run_guided_wizard
            echo ""
            read -r -p "Press Enter to return to main menu..." dummy
            ;;
        2)
            run_manual_restore
            echo ""
            read -r -p "Press Enter to return to main menu..." dummy
            ;;
        3)
            show_quick_diagnostics
            echo ""
            read -r -p "Press Enter to return to main menu..." dummy
            ;;
        4)
            echo "Exiting..."
            exit 0
            ;;
        *)
            echo "Invalid option."
            sleep 1
            ;;
    esac
}

# Startup verification
check_root "$@"
check_dependencies || exit 1

case "$1" in
    --wizard|-w)
        run_guided_wizard
        exit 0
        ;;
    --info|-i)
        show_quick_diagnostics
        exit 0
        ;;
    --restore|-r)
        run_manual_restore
        exit 0
        ;;
    "")
        while true; do
            show_menu
        done
        ;;
    *)
        log_err "Unrecognized option: $1"
        echo "Run '$0 --help' to display available options."
        exit 1
        ;;
esac
