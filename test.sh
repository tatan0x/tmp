#!/usr/bin/env bash

set -euo pipefail

declare -r TARGET_DISK="/dev/nvme0n1"
declare -r ROOT_PART_SIZE_GIB=512

declare -r EFI_PART_NAME="ARCH_EFI_PART"
declare -r BTRFS_ROOT_PART_NAME="ARCH_ROOT_PART"
declare -r BTRFS_HOME_PART_NAME="ARCH_HOME_PART"

declare -r EFI_FS_LABEL="ARCH_EFI"
declare -r BTRFS_ROOT_FS_LABEL="ARCH_ROOT"
declare -r BTRFS_HOME_FS_LABEL="ARCH_HOME"
declare -r SWAP_FS_LABEL="ARCH_SWAP"

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
size=1GiB,type=C12A7328-F81F-11D2-BA4B-00A0C93EC93B,name="${EFI_PART_NAME}"
size=${ROOT_PART_SIZE_GIB}GiB,type=0FC63DAF-8483-4772-8E79-3D69D8477DE4,name="${BTRFS_ROOT_PART_NAME}"
type=0FC63DAF-8483-4772-8E79-3D69D8477DE4,name="${BTRFS_HOME_PART_NAME}"
EOF
    _info "Partitioning complete. Waiting for kernel to recognize changes..."
    sleep 3 && partprobe "${TARGET_DISK}" || _warn "partprobe failed, kernel might need more time."
    sleep 2

    local efi_part="${TARGET_DISK}p1"
    local btrfs_root_part="${TARGET_DISK}p2"
    local btrfs_home_part="${TARGET_DISK}p3"

    [[ -b "${efi_part}" && -b "${btrfs_root_part}" && -b "${btrfs_home_part}" ]] || \
        _error "Partition devices not found after sfdisk. Check ${efi_part}, ${btrfs_root_part}, and ${btrfs_home_part}."

    _info "Formatting partitions..."
    mkfs.fat -F32 -n "${EFI_FS_LABEL}" "${efi_part}" || _error "mkfs.fat failed on ${efi_part}"
    mkfs.btrfs -f -L "${BTRFS_ROOT_FS_LABEL}" "${btrfs_root_part}" || _error "mkfs.btrfs failed on ${btrfs_root_part}"
    mkfs.btrfs -f -L "${BTRFS_HOME_FS_LABEL}" "${btrfs_home_part}" || _error "mkfs.btrfs failed on ${btrfs_home_part}"

    _info "Configuring Btrfs subvolumes and mounting filesystems..."
    
    _info "Mounting BTRFS root partition for subvolume creation..."
    mount -o "defaults,discard=async" "${btrfs_root_part}" /mnt || _error "Failed to mount BTRFS root partition for subvolume creation"
    
    declare -ar btrfs_root_subvols=( "@" "@log" "@pkg" "@tmp" "@swap" )
    _info "Creating BTRFS subvolumes on root partition: ${btrfs_root_subvols[*]}"
    for subvol in "${btrfs_root_subvols[@]}"; do
        btrfs subvolume create "/mnt/${subvol}" || _warn "Subvolume ${subvol} creation failed on root (may already exist)"
    done
    umount /mnt || _error "Failed to unmount temporary root BTRFS mount."

    _info "Mounting BTRFS home partition for subvolume creation..."
    mount -o "defaults,discard=async" "${btrfs_home_part}" /mnt || _error "Failed to mount BTRFS home partition for subvolume creation"
    
    _info "Creating BTRFS subvolume @home on home partition..."
    btrfs subvolume create "/mnt/@home" || _warn "Subvolume @home creation failed on home (may already exist)"
    umount /mnt || _error "Failed to unmount temporary home BTRFS mount."

    _info "Mounting final system layout..."
    local btrfs_mnt_opts="rw,noatime,ssd,compress=zstd:3,discard=async,space_cache=v2"
    
    mount -o "${btrfs_mnt_opts},subvol=@" "${btrfs_root_part}" /mnt
    _info "Mounted root subvolume."
    
    mkdir -p /mnt/{boot/efi,home,var/log,var/cache/pacman/pkg,tmp,swap}
    _info "Created standard system directories."

    mount -o "${btrfs_mnt_opts},subvol=@log"       "${btrfs_root_part}" /mnt/var/log
    mount -o "${btrfs_mnt_opts},subvol=@pkg"       "${btrfs_root_part}" /mnt/var/cache/pacman/pkg
    mount -o "${btrfs_mnt_opts},subvol=@tmp"       "${btrfs_root_part}" /mnt/tmp
    mount -o "${btrfs_mnt_opts},subvol=@swap"      "${btrfs_root_part}" /mnt/swap
    _info "Mounted root-based BTRFS subvolumes (@log, @pkg, @tmp, @swap)."

    mount -o "${btrfs_mnt_opts},subvol=@home"      "${btrfs_home_part}" /mnt/home
    _info "Mounted home subvolume (@home from separate partition)."

    local efi_mnt_opts="rw,noatime,fmask=0077,dmask=0077"
    mount -o "${efi_mnt_opts}" "${efi_part}" /mnt/boot/efi
    _info "Mounted EFI partition."

    _info "Setting up swapfile..."
    local swap_file="/mnt/swap/swapfile"
    truncate -s 0 "${swap_file}"
    chattr +C "${swap_file}"
    fallocate -l "${SWAP_SIZE_GIB}G" "${swap_file}" || {
        _warn "fallocate failed for swap, using dd as fallback..."
        dd if=/dev/zero of="${swap_file}" bs=1M count=$((SWAP_SIZE_GIB*1024)) status=none
    }
    chmod 0600 "${swap_file}" && mkswap -L "${SWAP_FS_LABEL}" "${swap_file}" && swapon "${swap_file}"
    _info "Swapfile setup complete."

    _info "Optimizing mirrorlist (Country: ${MIRROR_COUNTRY})..."
    reflector --country "${MIRROR_COUNTRY}" --protocol https --age 12 --sort rate --threads 0 --latest 20 --save /etc/pacman.d/mirrorlist || \
        _warn "Reflector failed. Pacstrap might use existing mirrors or fail."

    _info "Installing base system via pacstrap..."
    pacstrap /mnt "${CORE_PACKAGES[@]}" "${EXTRA_PACKAGES[@]}" || _error "Pacstrap failed."

    _info "Generating fstab..."
    genfstab -U -p /mnt >> /mnt/etc/fstab
    _info "fstab generated."
    _info "Content of generated /mnt/etc/fstab:"
    cat /mnt/etc/fstab

    _info "Configuring the new system (chroot environment)..."
    local kernel_params="nvidia-drm.modeset=1 nvme_core.default_ps_max_latency_us=0"

    _chroot \
        "echo 'Configuring mkinitcpio for NVIDIA Wayland...'" \
        "line=\$(grep '^MODULES=' /etc/mkinitcpio.conf || echo 'MODULES=()'); \
         current_mkinit_modules=''; \
         if [[ \"\${line}\" =~ ^MODULES=\\((.*)\\)\$ ]]; then \
            current_mkinit_modules=\"\${BASH_REMATCH[1]}\"; \
         elif [[ \"\${line}\" =~ ^MODULES=\\\"(.*)\\\"\$ ]]; then \
            current_mkinit_modules=\"\${BASH_REMATCH[1]}\"; \
         fi; \
         new_mkinit_modules=\"\${current_mkinit_modules} nvidia nvidia_modeset nvidia_uvm nvidia_drm\"; \
         new_mkinit_modules=\$(echo \${new_mkinit_modules} | xargs -n1 | sort -u | xargs); \
         if grep -q '^MODULES=' /etc/mkinitcpio.conf; then \
            sed -i \"s|^MODULES=.*|MODULES=(\${new_mkinit_modules})|\" /etc/mkinitcpio.conf; \
         else \
            echo \"MODULES=(\${new_mkinit_modules})\" >> /etc/mkinitcpio.conf; \
         fi; \
         echo 'Verifying mkinitcpio.conf changes:'; \
         grep '^MODULES=' /etc/mkinitcpio.conf || echo 'MODULES line not found/created!';" \
        "mkinitcpio -P" \
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

    _info "Installation with separate BTRFS /home partition, NVIDIA drivers, and Wayland prep finished."
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
    
    mountpoint -q /mnt/home && umount /mnt/home || _warn "Failed to unmount /mnt/home."
    mountpoint -q /mnt/var/log && umount /mnt/var/log || _warn "Failed to unmount /mnt/var/log."
    mountpoint -q /mnt/var/cache/pacman/pkg && umount /mnt/var/cache/pacman/pkg || _warn "Failed to unmount /mnt/var/cache/pacman/pkg."
    mountpoint -q /mnt/tmp && umount /mnt/tmp || _warn "Failed to unmount /mnt/tmp."
    
    if mountpoint -q /mnt/swap; then
        local swap_file_path_on_mnt="/mnt/swap/swapfile" 
        active_swap_paths=$(swapon --show=NAME --noheadings)
        if grep -q "${btrfs_root_part}" <<< "$active_swap_paths" || grep -q "/dev/mapper/" <<< "$active_swap_paths" || [[ $(swapon --show=NAME --noheadings | grep -c "$swap_file_path_on_mnt") -gt 0 ]] ; then
             if [[ -e "$swap_file_path_on_mnt" ]]; then
                swapoff "$swap_file_path_on_mnt" 2>/dev/null || _warn "swapoff for ${swap_file_path_on_mnt} failed (may not be active or path issue)."
             fi
        fi
        if [[ $(swapon --show=NAME --noheadings | grep -c "$swap_file_path_on_mnt") -gt 0 ]]; then
             _warn "Swap file ${swap_file_path_on_mnt} still seems active. Trying swapoff -a."
             swapoff -a || _warn "swapoff -a also failed."
        fi
        umount /mnt/swap || _warn "Failed to unmount /mnt/swap."
    fi

    if mountpoint -q /mnt; then
        umount -R /mnt || { _warn "Attempting lazy unmount for /mnt..."; umount -lR /mnt || _warn "Lazy unmount for /mnt also failed."; }
    else
        _info "/mnt not detected as a mount point during final cleanup."
    fi
    _info "Cleanup trap finished."
    exit "${exit_code}"
}
trap _final_cleanup_trap EXIT INT TERM

_main_installer "$@"
