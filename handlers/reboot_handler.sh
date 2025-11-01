#!/bin/bash
#
# reboot_handler.sh: Contains strategies for rebooting the system.
#

run_reboot_strategy() {
	prepare_reboot

	[[ -z $REBOOT_STRATEGY ]] && REBOOT_STRATEGY=reboot
	case "$REBOOT_STRATEGY" in
	reboot) do_full_reboot ;;
	kexec) do_kexec_reboot ;;
	*) do_abort "Unknown REBOOT_STRATEGY: ${REBOOT_STRATEGY}" ;;
	esac
}

kab_reboot() {
	run_cmd_and_wait systemctl reboot
}

signal_checkpoint_reboot() {
	signal_checkpoint "reboot"
}

do_full_reboot() {
	log "Strategy: Performing full reboot"
	if [[ -n $KAB_TEST_HOST ]]; then
		kab_reboot
	else
		log "Will use CRIU to restore the program"
		signal_checkpoint_reboot
	fi
}

do_kexec_reboot() {
	log "Strategy: kexec not supported with CRIU checkpointing, using full reboot..."
	# kexec bypasses the normal boot process, which would prevent the CRIU daemon
	# from properly restoring the process. Fall back to full reboot.
	do_full_reboot
}
