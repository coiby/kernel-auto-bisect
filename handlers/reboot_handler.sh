#!/bin/bash
#
# reboot_handler.sh: Contains strategies for rebooting the system.
#

run_reboot_strategy() {
    preapre_reboot
    case "$REBOOT_STRATEGY" in
        reboot) do_full_reboot ;;
        kexec)  do_kexec_reboot ;;
        *)      do_abort "Unknown REBOOT_STRATEGY: ${REBOOT_STRATEGY}" ;;
    esac
}

do_full_reboot() {
    log "Strategy: Performing full system reboot..."
    reboot
}

do_kexec_reboot() {
    log "Strategy: Performing kexec reboot..."
    local kernel_path="/boot/vmlinuz-$(cat $LAST_KERNEL_FILE)"
    local initrd_path="/boot/initramfs-$(cat $LAST_KERNEL_FILE).img"
    local cmdline=$(cat /proc/cmdline)

    if [ ! -f "$kernel_path" ] || [ ! -f "$initrd_path" ]; then
        log "kexec failed: kernel or initrd not found. Falling back to full reboot."
        do_full_reboot
    fi

    kexec -l "$kernel_path" --initrd="$initrd_path" --command-line="$cmdline"
    log "kexec loaded. Rebooting now."
    kexec -e
    
    # Safety fallback
    log "kexec -e failed. Forcing full reboot."
    do_full_reboot
}

