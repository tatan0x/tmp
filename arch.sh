#!/usr/bin/env bash

set -euo pipefail

declare -r TARGET_DISK="/dev/nvme0n1"
declare -r EFI_PART_LABEL="ARCH_EFI"
declare -r BTRFS_VOL_LABEL="ARCH_ROOT"
declare -r SWAP_VOL_LABEL="ARCH_SWAP"

declare -r TIME_ZONE="Asia/Jakarta"
declare -r CONSOLE_KEYMAP="us"
declare -r SYSTEM_LOCALE="en_US.UTF-8"

declare -r MIRROR_COUNTRY="Indonesia"
declare -r SWAP_SIZE_GIB=16

declare -r KERNEL_PKG="linux"
declare -r CPU_UCODE_PKG="intel-ucode"
declare -ar GPU_DRIVER_PKGS=("nvidia" "nvidia-utils")

declare -ar CORE_PACKAGES=(
    "base" "base-devel" "${KERNEL_PKG}" "${KERNEL_PKG}-headers" "linux-firmware" "sof-firmware"
    "${CPU_UCODE_PKG}" "${GPU_DRIVER_PKGS[@]}"
    "efibootmgr" "btrfs-progs" "grub" "grub-btrfs" "reflector"
    "networkmanager" "pipewire" "pipewire-alsa" "pipewire-pulse" "wireplumber"
    "openssh" "man-db" "man-pages" "git" "rsync" "bluez" "bluez-utils" "nano" "fd"
    "timeshift" "wireless-regdb" "lm_sensors" "smartmontools"
)
declare -ar EXTRA_PACKAGES=(
    "gnome-shell" "gnome-session" "nautilus" "gnome-control-center" "gnome-terminal" "gnome-tweaks" "xdg-desktop-portal-gnome" "gdm"
)

declare HOST_NAME=""
declare DEFAULT_USER=""

_log() { local level="$1"; shift; printf '%s [%s] %s\n' "$(date +"%Y-%m-%d %T")" "${level}" "$*"; }
_info()    { _log "INFO" "$@"; }
_warn()    { _log "WARN" "$@"; }
_error()   { _log "ERROR" "$*" >&2; exit 1; }

_confirm_destructive() {
    _warn "TARGET DISK FOR ALL OPERATIONS: ${TARGET_DISK}"
    read -r -p "CONFIRM 1/2: All data on ${TARGET_DISK} will be ERASED. Proceed? (Type 'yes' to confirm): " r1
    [[ "${r1,,}" == "yes" ]] || _error "User aborted (Confirmation 1/2 failed)."
    read -r -p "CONFIRM 2/2: This is your FINAL chance. Are you ABSOLUTELY SURE? (Type 'YES' in uppercase): " r2
    [[ "${r2}" == "YES" ]] || _error "User aborted (Confirmation 2/2 failed - uppercase YES not entered)."
}

_prompt_input() {
    local -n var_ref="$1"
    local prompt_msg="$2"
    local default_val="${3:-}"
    local user_input

    while true; do
        if [[ -n "$default_val" ]]; then
            read -r -p "INPUT: Enter ${prompt_msg} [default: ${default_val}]: " user_input
            user_input="${user_input:-$default_val}"
        else
            read -r -p "INPUT: Enter ${prompt_msg}: " user_input
        fi

        if [[ -z "$user_input" ]]; then
            _warn "${prompt_msg} cannot be empty. Please try again."
        else
            var_ref="$user_input"
            break
        fi
    done
    _info "${prompt_msg} set to: ${var_ref}"
}

_chroot() {
    for cmd_str in "$@"; do
        _info "CHROOTCMD: ${cmd_str}"
        arch-chroot /mnt /bin/bash -c "${cmd_str}" || _error "Chroot command failed: [${cmd_str}]"
    done
}

_main_installer() {
    [[ "$(id -u)" -eq 0 ]] || _error "Script must be run as root."
    lsblk "${TARGET_DISK}" >/dev/null 2>&1 || _error "Target disk ${TARGET_DISK} not found. Verify configuration."

    _warn "THIS SCRIPT WILL AUTOMATICALLY PARTITION AND FORMAT '${TARGET_DISK}'."
    _confirm_destructive

    _prompt_input HOST_NAME "desired Hostname" "archclean"
    _prompt_input DEFAULT_USER "desired Username (lowercase, no spaces)" "builder"

    _info "Setting up live environment (NTP, keymap)..."
    timedatectl set-ntp true
    loadkeys "${CONSOLE_KEYMAP}" >/dev/null 2>&1

    _info "Starting automated partitioning of ${TARGET_DISK}..."
    sfdisk --delete "${TARGET_DISK}" || _warn "sfdisk --delete failed (disk might be empty or in use, proceeding)."
    
    sfdisk "${TARGET_DISK}" --label gpt << EOF
size=1GiB,type=C12A7328-F81F-11D2-BA4B-00A0C93EC93B,name="${EFI_PART_LABEL}"
type=0FC63DAF-8483-4772-8E79-3D69D8477DE4,name="${BTRFS_VOL_LABEL}"
EOF
    _info "Partitioning complete. Waiting for kernel to recognize changes..."
    sleep 3 && partprobe "${TARGET_DISK}" || _warn "partprobe failed, kernel might need more time."
    sleep 2

    local efi_part="${TARGET_DISK}p1"
    local btrfs_part="${TARGET_DISK}p2"
    [[ -b "${efi_part}" && -b "${btrfs_part}" ]] || _error "Partition devices not found after sfdisk. Check ${efi_part} and ${btrfs_part}."

    _info "Formatting partitions..."
    mkfs.fat -F32 -n "${EFI_PART_LABEL}" "${efi_part}" || _error "mkfs.fat failed on ${efi_part}"
    mkfs.btrfs -f -L "${BTRFS_VOL_LABEL}" "${btrfs_part}" || _error "mkfs.btrfs failed on ${btrfs_part}"

    _info "Configuring Btrfs subvolumes and mounting filesystems..."
    mount -o "defaults,discard=async" "${btrfs_part}" /mnt || _error "Failed to mount BTRFS root for subvolume creation"

    declare -ar btrfs_subvols=( "@" "@home" "@log" "@pkg" "@tmp" "@swap" )
    for subvol in "${btrfs_subvols[@]}"; do
        btrfs subvolume create "/mnt/${subvol}" || _warn "Subvolume ${subvol} creation failed (may already exist)"
    done
    umount /mnt

    local btrfs_mnt_opts="rw,noatime,ssd,compress=zstd:3,discard=async,space_cache=v2"
    mount -o "${btrfs_mnt_opts},subvol=@" "${btrfs_part}" /mnt
    mkdir -p /mnt/{boot/efi,home,var/log,var/cache/pacman/pkg,tmp,swap}

    mount -o "${btrfs_mnt_opts},subvol=@home"      "${btrfs_part}" /mnt/home
    mount -o "${btrfs_mnt_opts},subvol=@log"       "${btrfs_part}" /mnt/var/log
    mount -o "${btrfs_mnt_opts},subvol=@pkg"       "${btrfs_part}" /mnt/var/cache/pacman/pkg
    mount -o "${btrfs_mnt_opts},subvol=@tmp"       "${btrfs_part}" /mnt/tmp
    mount -o "${btrfs_mnt_opts},subvol=@swap"      "${btrfs_part}" /mnt/swap
    mount -o "rw,noatime,fmask=0133,dmask=0022,iocharset=iso8859-1,errors=remount-ro" "${efi_part}" /mnt/boot/efi

    _info "Setting up swapfile..."
    local swap_file="/mnt/swap/swapfile"
    truncate -s 0 "${swap_file}"
    chattr +C "${swap_file}"
    fallocate -l "${SWAP_SIZE_GIB}G" "${swap_file}" || {
        _warn "fallocate failed for swap, using dd as fallback..."
        dd if=/dev/zero of="${swap_file}" bs=1M count=$((SWAP_SIZE_GIB*1024)) status=none
    }
    chmod 0600 "${swap_file}" && mkswap -L "${SWAP_VOL_LABEL}" "${swap_file}" && swapon "${swap_file}"

    _info "Optimizing mirrorlist (Country: ${MIRROR_COUNTRY})..."
    reflector --country "${MIRROR_COUNTRY}" --protocol https --age 12 --sort rate --threads 0 --latest 20 --save /etc/pacman.d/mirrorlist || \
        _warn "Reflector failed. Pacstrap might use existing mirrors or fail."

    _info "Installing base system via pacstrap..."
    pacstrap /mnt "${CORE_PACKAGES[@]}" "${EXTRA_PACKAGES[@]}" || _error "Pacstrap failed."

    _info "Generating fstab..."
    genfstab -U -p /mnt >> /mnt/etc/fstab

    _info "Configuring the new system (chroot environment)..."
    local kernel_params="nvidia-drm.modeset=1 nvme_core.default_ps_max_latency_us=0"

    _chroot \
        "ln -sf /usr/share/zoneinfo/${TIME_ZONE} /etc/localtime" \
        "hwclock --systohc --utc" \
        "echo '${HOST_NAME}' > /etc/hostname" \
        "echo -e '127.0.0.1 localhost\n::1       localhost\n127.0.1.1 ${HOST_NAME}.localdomain ${HOST_NAME}' > /etc/hosts" \
        "echo \"LANG=${SYSTEM_LOCALE}\" > /etc/locale.conf" \
        "echo \"KEYMAP=${CONSOLE_KEYMAP}\" > /etc/vconsole.conf" \
        "sed -i '/^#${SYSTEM_LOCALE}/s/^#//' /etc/locale.gen && locale-gen" \
        "grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=ARCH --recheck" \
        "current_cmdline=\$(grep '^GRUB_CMDLINE_LINUX_DEFAULT=' /etc/default/grub | cut -d '\"' -f2); \
         new_cmdline=\"\${current_cmdline} ${kernel_params}\"; \
         new_cmdline=\$(echo \"\${new_cmdline}\" | xargs -r); \
         sed -i \"s|^GRUB_CMDLINE_LINUX_DEFAULT=.*|GRUB_CMDLINE_LINUX_DEFAULT=\\\"\${new_cmdline}\\\"|\" /etc/default/grub" \
        "grub-mkconfig -o /boot/grub/grub.cfg"

    _warn "You will now be prompted to set the ROOT password:"
    arch-chroot /mnt passwd root || _error "Failed to set root password."

    _info "Enabling essential system services (PipeWire services NOT enabled at this stage)..."
    declare -ar services_to_enable=(
        "NetworkManager.service" "sshd.service" "bluetooth.service" "reflector.timer" "fstrim.timer"
        "smartd.service" "systemd-timesyncd.service" "gdm.service"
    )
    for service in "${services_to_enable[@]}"; do _chroot "systemctl enable ${service}"; done

    _info "Creating user '${DEFAULT_USER}'..."
    _chroot "useradd -m -G wheel '${DEFAULT_USER}'"
    _warn "You will now be prompted to set the password for user '${DEFAULT_USER}':"
    arch-chroot /mnt passwd "${DEFAULT_USER}" || _error "Failed to set user password."
    _chroot "echo '%wheel ALL=(ALL:ALL) ALL' > /etc/sudoers.d/10_wheel_sudo && chmod 0440 /etc/sudoers.d/10_wheel_sudo"

    if [[ " ${CORE_PACKAGES[*]} " == *"lm_sensors"* ]]; then
        _warn "Running sensors-detect in chroot. This is semi-interactive or will accept defaults."
        _chroot "timeout 30s yes '' | sensors-detect --auto" || _warn "sensors-detect had issues or timed out. Configure manually later if needed."
    fi

    _info "Ultra-minimal Arch Linux CLI base installation finished. System is ready for a clean snapshot."
    _info "Audio services (PipeWire) will need to be configured/started by your Desktop Environment or Window Manager."
    _info "Time synchronization (systemd-timesyncd) has been enabled."
    _info "Unmounting filesystems. Type 'reboot' after script exits."
}

_final_cleanup_trap() {
    local exit_code=$?
    if [[ "$exit_code" -eq 0 ]]; then
        _info "Script completed successfully."
    else
        _log "FATAL" "Script exited with error code: ${exit_code}."
    fi

    _info "Attempting final unmount of /mnt resources..."
    sync
    mountpoint -q /mnt/boot/efi && umount -R /mnt/boot/efi || _warn "Failed to unmount /mnt/boot/efi cleanly."
    if mountpoint -q /mnt; then
        swapoff -a || _warn "swapoff failed (already off or unmounted?)."
        umount -R /mnt || { _warn "Attempting lazy unmount for /mnt..."; umount -lR /mnt || _warn "Lazy unmount for /mnt also failed."; }
    else
        _info "/mnt not detected as a mount point during final cleanup."
    fi
    _info "Cleanup trap finished."
    exit "${exit_code}"
}
trap _final_cleanup_trap EXIT INT TERM

_main_installer "$@"
