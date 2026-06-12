#!/usr/bin/env bash
#
# arch-recovery.sh - Diagnostic tool for non-booting Arch Linux systems
# Run this from an Arch ISO / live environment.
#
# License: GPLv3
#
set -uo pipefail

VERSION="0.1.0"

# ---------- colors / formatting ----------
C_RESET="\033[0m"
C_BOLD="\033[1m"
C_GREEN="\033[32m"
C_YELLOW="\033[33m"
C_RED="\033[31m"
C_BLUE="\033[34m"

PASS_COUNT=0
WARN_COUNT=0
FAIL_COUNT=0

REPORT=()

log_pass() {
    echo -e "${C_GREEN}[PASS]${C_RESET} $1"
    REPORT+=("[PASS] $1")
    ((PASS_COUNT++))
}

log_warn() {
    echo -e "${C_YELLOW}[WARN]${C_RESET} $1"
    REPORT+=("[WARN] $1")
    ((WARN_COUNT++))
}

log_fail() {
    echo -e "${C_RED}[FAIL]${C_RESET} $1"
    REPORT+=("[FAIL] $1")
    ((FAIL_COUNT++))
}

log_info() {
    echo -e "${C_BLUE}[INFO]${C_RESET} $1"
}

section() {
    echo
    echo -e "${C_BOLD}== $1 ==${C_RESET}"
}

# ---------- global state ----------
TARGET_ROOT=""       # mountpoint of the target system's root, e.g. /mnt
TARGET_DEV=""        # block device of target root, e.g. /dev/sda2
DID_MOUNT=0          # 1 if we mounted it ourselves (so we can offer to unmount)

# ---------- helpers ----------
require_root() {
    if [[ "$EUID" -ne 0 ]]; then
        echo "This tool needs root privileges (to mount partitions, chroot, etc)."
        echo "Re-run with: sudo $0"
        exit 1
    fi
}

# Try to find a likely root partition automatically.
# Strategy: list partitions with a Linux filesystem, let user pick if multiple.
detect_root_partition() {
    section "Detecting target root partition"

    mapfile -t candidates < <(lsblk -rno NAME,FSTYPE,SIZE,TYPE | \
        awk '$4=="part" && ($2=="ext4" || $2=="btrfs" || $2=="xfs" || $2=="f2fs") {print "/dev/"$1" "$2" "$3}')

    if [[ ${#candidates[@]} -eq 0 ]]; then
        log_fail "No Linux filesystem partitions found via lsblk."
        return 1
    fi

    if [[ ${#candidates[@]} -eq 1 ]]; then
        TARGET_DEV=$(echo "${candidates[0]}" | awk '{print $1}')
        log_info "Found one candidate: $TARGET_DEV (${candidates[0]})"
    else
        echo "Multiple candidate partitions found:"
        local i=1
        for c in "${candidates[@]}"; do
            echo "  $i) $c"
            ((i++))
        done
        read -rp "Select the number of your Arch root partition: " choice
        TARGET_DEV=$(echo "${candidates[$((choice-1))]}" | awk '{print $1}')
    fi

    log_info "Selected target device: $TARGET_DEV"
    return 0
}

mount_target() {
    section "Mounting target system"

    TARGET_ROOT="/mnt/arch-recovery"
    mkdir -p "$TARGET_ROOT"

    if mountpoint -q "$TARGET_ROOT"; then
        log_info "$TARGET_ROOT already mounted, using existing mount."
        return 0
    fi

    if mount "$TARGET_DEV" "$TARGET_ROOT" 2>/dev/null; then
        log_pass "Mounted $TARGET_DEV at $TARGET_ROOT"
        DID_MOUNT=1
    else
        log_fail "Could not mount $TARGET_DEV at $TARGET_ROOT"
        return 1
    fi

    # Mount boot partition if it's separate (common with systemd-boot/EFI setups)
    if [[ -d "$TARGET_ROOT/boot" ]]; then
        # find an unmounted ESP/boot partition - best effort, non-fatal
        local boot_dev
        boot_dev=$(lsblk -rno NAME,FSTYPE,PARTTYPE | awk '$2=="vfat" {print "/dev/"$1}' | head -n1)
        if [[ -n "$boot_dev" ]] && ! mountpoint -q "$TARGET_ROOT/boot"; then
            mount "$boot_dev" "$TARGET_ROOT/boot" 2>/dev/null && \
                log_info "Mounted boot partition $boot_dev at $TARGET_ROOT/boot" || \
                log_warn "Could not auto-mount a separate /boot partition (may not exist, that's OK)"
        fi
    fi

    return 0
}

cleanup() {
    if [[ "$DID_MOUNT" -eq 1 && -n "$TARGET_ROOT" ]]; then
        echo
        read -rp "Unmount $TARGET_ROOT before exiting? [Y/n] " ans
        if [[ ! "$ans" =~ ^[Nn]$ ]]; then
            umount -R "$TARGET_ROOT" 2>/dev/null && log_info "Unmounted $TARGET_ROOT"
        fi
    fi
}
trap cleanup EXIT

# ---------- checks ----------

check_bootloader() {
    section "Bootloader check"

    if [[ -d "$TARGET_ROOT/boot/loader/entries" ]]; then
        log_info "systemd-boot detected (loader entries present)."
        local entries
        entries=$(find "$TARGET_ROOT/boot/loader/entries" -name "*.conf" 2>/dev/null)
        if [[ -z "$entries" ]]; then
            log_fail "No boot entries found in /boot/loader/entries — system has nothing to boot into."
            return
        fi
        for entry in $entries; do
            log_info "Checking $entry"
            local linux_path initrd_path
            linux_path=$(grep -E '^linux ' "$entry" | awk '{print $2}')
            initrd_path=$(grep -E '^initrd ' "$entry" | awk '{print $2}')

            if [[ -n "$linux_path" ]]; then
                if [[ -f "$TARGET_ROOT/boot$linux_path" ]] || [[ -f "$TARGET_ROOT$linux_path" ]]; then
                    log_pass "Kernel image referenced by $(basename "$entry") exists ($linux_path)"
                else
                    log_fail "Kernel image $linux_path referenced in $(basename "$entry") is MISSING"
                fi
            else
                log_warn "$(basename "$entry") has no 'linux' line"
            fi

            if [[ -n "$initrd_path" ]]; then
                if [[ -f "$TARGET_ROOT/boot$initrd_path" ]] || [[ -f "$TARGET_ROOT$initrd_path" ]]; then
                    log_pass "Initramfs referenced by $(basename "$entry") exists ($initrd_path)"
                else
                    log_fail "Initramfs $initrd_path referenced in $(basename "$entry") is MISSING"
                fi
            fi
        done
    elif [[ -f "$TARGET_ROOT/boot/grub/grub.cfg" ]]; then
        log_info "GRUB detected (grub.cfg present)."
        if grep -q "^menuentry" "$TARGET_ROOT/boot/grub/grub.cfg"; then
            log_pass "grub.cfg contains at least one menuentry"
        else
            log_fail "grub.cfg has no menuentry blocks — likely needs regeneration (grub-mkconfig)"
        fi

        # Check root UUID in grub.cfg matches actual root partition UUID
        local actual_uuid cfg_uuids
        actual_uuid=$(blkid -s UUID -o value "$TARGET_DEV")
        if grep -q "$actual_uuid" "$TARGET_ROOT/boot/grub/grub.cfg"; then
            log_pass "Root partition UUID ($actual_uuid) found in grub.cfg"
        else
            log_warn "Root partition UUID ($actual_uuid) NOT found in grub.cfg — possible stale config after disk change"
        fi
    else
        log_fail "No recognizable bootloader config found (no systemd-boot entries, no grub.cfg)"
    fi
}

check_fstab() {
    section "fstab validation"

    local fstab="$TARGET_ROOT/etc/fstab"
    if [[ ! -f "$fstab" ]]; then
        log_fail "/etc/fstab does not exist on target system"
        return
    fi

    local lineno=0
    while IFS= read -r line; do
        ((lineno++))
        # skip comments/blank lines
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ -z "${line// /}" ]] && continue

        local src mountpoint fstype
        src=$(awk '{print $1}' <<< "$line")
        mountpoint=$(awk '{print $2}' <<< "$line")
        fstype=$(awk '{print $3}' <<< "$line")

        # resolve UUID=/LABEL= entries
        local resolved_dev=""
        if [[ "$src" =~ ^UUID= ]]; then
            resolved_dev=$(blkid -U "${src#UUID=}" 2>/dev/null)
        elif [[ "$src" =~ ^LABEL= ]]; then
            resolved_dev=$(blkid -L "${src#LABEL=}" 2>/dev/null)
        elif [[ "$src" =~ ^/dev/ ]]; then
            resolved_dev="$src"
        fi

        if [[ -n "$resolved_dev" && ! -e "$resolved_dev" ]]; then
            log_fail "fstab line $lineno: device $src ($resolved_dev) does not exist — mounting $mountpoint will fail"
        elif [[ -z "$resolved_dev" && "$fstype" != "swap" && "$src" != "tmpfs" ]]; then
            log_warn "fstab line $lineno: could not resolve device for '$src' (mountpoint $mountpoint)"
        else
            log_pass "fstab line $lineno: $src -> $mountpoint looks resolvable"
        fi
    done < "$fstab"
}

check_last_boot_errors() {
    section "Last boot journal errors"

    if ! command -v journalctl &>/dev/null; then
        log_warn "journalctl not available in live environment, skipping"
        return
    fi

    # Use journalctl with -D to point at the target's journal
    local journal_dir="$TARGET_ROOT/var/log/journal"
    if [[ ! -d "$journal_dir" ]]; then
        log_warn "No persistent journal found at $journal_dir (journald may be using volatile storage)"
        return
    fi

    local errors
    errors=$(journalctl -D "$journal_dir" -b -1 -p err --no-pager 2>/dev/null | tail -n 20)

    if [[ -z "$errors" ]]; then
        log_pass "No 'err' level messages found in previous boot's journal (or no previous boot logged)"
    else
        log_warn "Found error-level messages in the last boot's journal (showing up to 20 most recent):"
        while IFS= read -r line; do
            echo "    $line"
        done <<< "$errors"
    fi
}

check_aur_packages() {
    section "Foreign/AUR package audit"

    if ! command -v arch-chroot &>/dev/null; then
        log_warn "arch-chroot not found, skipping AUR/pacman checks"
        return
    fi

    # Get list of foreign (AUR) packages
    local foreign
    foreign=$(arch-chroot "$TARGET_ROOT" pacman -Qm 2>/dev/null)

    if [[ -z "$foreign" ]]; then
        log_pass "No foreign (AUR/manually installed) packages found"
    else
        local count
        count=$(echo "$foreign" | wc -l)
        log_info "Found $count foreign package(s):"
        while IFS= read -r pkg; do
            echo "    - $pkg"
        done <<< "$foreign"
    fi

    # Cross-reference with pacman log for recent updates
    local pac_log="$TARGET_ROOT/var/log/pacman.log"
    if [[ -f "$pac_log" ]]; then
        log_info "Most recent package transactions (last 10):"
        grep -E "\[ALPM\] (upgraded|installed|removed)" "$pac_log" | tail -n 10 | while IFS= read -r line; do
            echo "    $line"
        done

        # Highlight if a foreign package was recently upgraded
        if [[ -n "$foreign" ]]; then
            while IFS=' ' read -r pkgname _; do
                if grep -q "upgraded $pkgname " "$pac_log"; then
                    local last_upgrade
                    last_upgrade=$(grep "upgraded $pkgname " "$pac_log" | tail -n1)
                    log_warn "Foreign package '$pkgname' was upgraded recently: $last_upgrade"
                fi
            done <<< "$foreign"
        fi
    else
        log_warn "No pacman.log found at $pac_log"
    fi

    # Check for .pacnew files (often indicate config drift after updates)
    local pacnew_files
    pacnew_files=$(find "$TARGET_ROOT/etc" -name "*.pacnew" 2>/dev/null)
    if [[ -n "$pacnew_files" ]]; then
        log_warn "Found .pacnew files (unmerged config updates) — these MAY relate to your issue:"
        while IFS= read -r f; do
            echo "    - $f"
        done <<< "$pacnew_files"
    else
        log_pass "No .pacnew files found in /etc"
    fi
}

check_mkinitcpio() {
    section "Initramfs / mkinitcpio config"

    local conf="$TARGET_ROOT/etc/mkinitcpio.conf"
    if [[ ! -f "$conf" ]]; then
        log_fail "/etc/mkinitcpio.conf not found"
        return
    fi

    log_pass "/etc/mkinitcpio.conf exists"

    # Check for nvidia hook presence if nvidia-dkms is installed (common breakage)
    if command -v arch-chroot &>/dev/null; then
        if arch-chroot "$TARGET_ROOT" pacman -Q nvidia-dkms &>/dev/null; then
            if grep -qE "^HOOKS=.*nvidia" "$conf" || grep -qE "^MODULES=.*nvidia" "$conf"; then
                log_pass "nvidia-dkms is installed and nvidia modules/hooks appear in mkinitcpio.conf"
            else
                log_warn "nvidia-dkms is installed but no nvidia modules/hooks found in mkinitcpio.conf — initramfs may be missing nvidia driver, causing boot to fail or blank screen"
            fi
        fi
    fi

    # Check initramfs images exist for installed kernels
    if command -v arch-chroot &>/dev/null; then
        local kernels
        kernels=$(arch-chroot "$TARGET_ROOT" pacman -Q 2>/dev/null | awk '/^linux($| |-zen|-lts|-hardened)/ {print $1}')
        for k in $kernels; do
            local img="$TARGET_ROOT/boot/initramfs-${k}.img"
            if [[ -f "$img" ]]; then
                log_pass "Initramfs image exists for $k ($img)"
            else
                log_fail "Missing initramfs image for installed kernel '$k' (expected $img) — run 'mkinitcpio -P' from chroot"
            fi
        done
    fi
}

print_summary() {
    section "Summary"
    echo -e "${C_GREEN}PASS: $PASS_COUNT${C_RESET}  ${C_YELLOW}WARN: $WARN_COUNT${C_RESET}  ${C_RED}FAIL: $FAIL_COUNT${C_RESET}"
    echo
    if [[ "$FAIL_COUNT" -gt 0 ]]; then
        echo "Some checks failed. Review the [FAIL] lines above for likely causes."
    elif [[ "$WARN_COUNT" -gt 0 ]]; then
        echo "No hard failures, but some warnings were found — review [WARN] lines."
    else
        echo "All checks passed. The boot issue may be hardware-related or outside this tool's checks."
    fi

    echo
    read -rp "Save full report to a file? [y/N] " save
    if [[ "$save" =~ ^[Yy]$ ]]; then
        local outfile="./arch-recovery-report-$(date +%Y%m%d-%H%M%S).txt"
        printf '%s\n' "${REPORT[@]}" > "$outfile"
        echo "Report saved to $outfile"
    fi
}

main() {
    echo -e "${C_BOLD}arch-recovery.sh v$VERSION${C_RESET}"
    echo "A diagnostic tool for non-booting Arch Linux systems."
    echo

    require_root

    if ! detect_root_partition; then
        echo "Could not auto-detect a root partition. Exiting."
        exit 1
    fi

    if ! mount_target; then
        echo "Could not mount target system. Exiting."
        exit 1
    fi

    check_bootloader
    check_fstab
    check_mkinitcpio
    check_last_boot_errors
    check_aur_packages

    print_summary
}

main "$@"
