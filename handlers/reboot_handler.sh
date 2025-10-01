#!/bin/bash
#
# reboot_handler.sh: Contains strategies for rebooting the system.
#

run_reboot_strategy() {
	prepare_reboot
	case "$REBOOT_STRATEGY" in
	reboot) do_full_reboot ;;
	kexec) do_kexec_reboot ;;
	*) do_abort "Unknown REBOOT_STRATEGY: ${REBOOT_STRATEGY}" ;;
	esac
}

do_full_reboot() {
	log "Strategy: Performing checkpoint+reboot via daemon..."
	signal_checkpoint_reboot
}

do_kexec_reboot() {
	log "Strategy: kexec not supported with CRIU checkpointing, using full reboot..."
	# kexec bypasses the normal boot process, which would prevent the CRIU daemon
	# from properly restoring the process. Fall back to full reboot.
	do_full_reboot
}
