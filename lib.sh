#!/bin/bash
# Configuration
BIN_DIR=/usr/local/bin/kernel-auto-bisect
WORK_DIR="/var/local/kernel-auto-bisect"
GIT_REPO="$WORK_DIR/git_repo"
SIGNAL_DIR="$WORK_DIR/signal"
DUMP_DIR="$WORK_DIR/dump"
DUMP_LOG_DIR="$WORK_DIR/dump_logs"
CHECKPOINT_SIGNAL="$SIGNAL_DIR/checkpoint_request"
RESTORE_FLAG="$SIGNAL_DIR/restore_flag"
PANIC_SIGNAL="$SIGNAL_DIR/panic_request"

CONFIG_FILE="$BIN_DIR/bisect.conf"
HANDLER_DIR="$BIN_DIR/handlers"
LOG_FILE="$WORK_DIR/main.log"

CRIU_LOG_FILE="$WORK_DIR/criu-daemon.log"
BISECT_SCRIPT="$BIN_DIR/kab.sh"

LAST_TESTED_KERNEL=""
ORIGINAL_KERNEL=""
GOOD_REF=""
BAD_REF=""

# --- Load Config and Handlers ---
load_config_and_handlers() {
	if [ ! -f "$CONFIG_FILE" ]; then
		echo "FATAL: Config file missing!" | tee -a "$LOG_FILE"
		exit 1
	fi
	source "$CONFIG_FILE"
	for handler in "${HANDLER_DIR}"/*.sh; do if [ -f "$handler" ]; then source "$handler"; fi; done
	rm -rf $DUMP_DIR/*
	if ! dnf install git -yq; then
		exit 1
	fi
	# 1. setsid somehow doesn't work, checkpointing will fail with "The criu itself is within dumped tree"
	#    setsid criu-daemon.sh < /dev/null &> log_file &
	# 2. Using a systemd service to start criu-daemon.sh somehow can lead to many
	#    dump/restore issues like "can't write lsm profile"
	systemd-run --unit=checkpoint-test $BIN_DIR/criu-daemon.sh
}

safe_cd() {
	cd "$1" || {
		echo "Failed to cd $1"
		exit 1
	}
}

# --- Logging ---
log() { echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"; }

# --- Kernel and Grub Management ---
set_boot_kernel() {
	log "Setting default boot kernel to: $1"
	grubby --set-default "$1"
}

get_original_kernel() {
	grubby --info=/boot/vmlinuz-$(uname -r) | grep -E "^kernel=" | sed 's/kernel=//;s/"//g'
}

FIRST_SIGNALED=true
_wait_tmt_test() {
	[[ -z $TMT_SLEEP_MARK ]] && return

	if $FIRST_SIGNALED; then
		FIRST_SIGNALED=false
		return
	fi

	local _wait_time=0
	MAX_WAIT_TMT_TIME=60
	until pgrep -f "sleep $TMT_SLEEP_MARK" >/dev/null; do
		sleep 1
		((++_wait_time))
		if [[ $_wait_time -ge $MAX_WAIT_TMT_TIME ]]; then
			echo "$KAB_TMT_TEST_SLEEP_FLAG still isn't created after ${MAX_WAIT_TMT_TIME}, something wrong. Exiting!"
			exit 1
		fi
	done
}

signal_checkpoint() {
	mkdir -p "$SIGNAL_DIR"

	_wait_tmt_test

	log "Signaling daemon to checkpoint and reboot"

	if [[ $1 == reboot ]]; then
		printf "sync\n systemctl reboot" >"$CHECKPOINT_SIGNAL"
	elif [[ $1 == panic ]]; then
		printf "sync\n echo 1 > /proc/sys/kernel/sysrq\n echo c > /proc/sysrq-trigger" >"$CHECKPOINT_SIGNAL"
	fi

	# Wait for the daemon to process our request and reboot/panic the system
	# If we're still running after 10 seconds, something went wrong
	local count=0
	local MAX_WAIT=20
	while [[ ! -f "$RESTORE_FLAG" ]] && [[ $count -lt $MAX_WAIT ]]; do
		sleep 1
		count=$((count + 1))
	done

	rm -f "$RESTORE_FLAG"
	if [[ $count -ge $MAX_WAIT ]]; then
		log "ERROR: Daemon failed to process checkpoint request"
		exit 1
	fi
}

declare -A release_commit_map

signal_checkpoint_reboot() {
	signal_checkpoint "reboot"
}

signal_checkpoint_panic() {
	signal_checkpoint "panic"
}

prepare_reboot() {
	# try to reboot to current EFI bootloader entry next time
	command -v rstrnt-prepare-reboot &>/dev/null && rstrnt-prepare-reboot >/dev/null
	sync
}

remove_last_kernel() {
	# This function is now only called during do_abort to clean up the final state.
	if [[ -z "$LAST_TESTED_KERNEL" ]]; then return; fi
	local kernel_to_remove="$LAST_TESTED_KERNEL"
	# Safety check: never remove the original kernel
	if [[ -z "$kernel_to_remove" ]] || [[ "/boot/vmlinuz-$(uname -r)" == "$ORIGINAL_KERNEL" ]]; then
		log "WARNING: Skipping removal of last kernel, as it is running or undefined."
		LAST_TESTED_KERNEL=""
		return
	fi
	log "Cleaning up last tested kernel: ${kernel_to_remove}"
	case "$INSTALL_STRATEGY" in
	rpm) rpm -e "kernel-core-${kernel_to_remove}" >/dev/null 2>&1 || log "Failed to remove kernel RPMs." ;;
	git)
		kernel-install remove ${kernel_to_remove}
		rm -rf /lib/modules/${kernel_to_remove}
		;;
	esac
	LAST_TESTED_KERNEL=""
}

do_abort() {
	log "FATAL: $1"
	log "Aborting bisection."
	if [[ "$INSTALL_STRATEGY" == "git" ]] && [ -d "$KERNEL_SRC_DIR" ]; then
		cd "$KERNEL_SRC_DIR"
		git bisect reset || true
	fi
	if [[ -n "$ORIGINAL_KERNEL" ]]; then
		log "Returning to original kernel."
		set_boot_kernel "$ORIGINAL_KERNEL"
	fi
	#remove_last_kernel
	log "To perform a full cleanup of all intermediate kernels, please do so manually."
	exit 1
}

# --- RPM Mode Specific Functions ---
generate_git_repo_from_package_list() {
	log "Generating fake git repository for RPM list..."
	rm -rf "$GIT_REPO"
	mkdir -p "$GIT_REPO"
	safe_cd "$GIT_REPO"
	git init -q
	git config user.name kab
	git config user.email kab
	touch k_url k_rel
	git add k_url k_rel
	git commit -m "init" >/dev/null
	while read -r _url; do
		local _str=$(basename "$_url")
		_str=${_str#kernel-core-}
		local k_rel=${_str%.rpm}
		echo "$_url" >k_url
		echo "$k_rel" >k_rel
		git commit -m "$k_rel" k_url k_rel >/dev/null
		release_commit_map[$k_rel]=$(git rev-parse HEAD)
	done <"$KERNEL_RPM_LIST"
}

setup_criu() {
	if ! command -v criu; then
		if ! dnf install criu -yq; then
			log "Failed to install criu!"
			exit 1
		fi
	fi

	CRONTAB="$WORK_DIR/crontab"
	cat <<END >"$CRONTAB"
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:$BIN_DIR
@reboot criu-daemon.sh
# It seems @reboot doesn't work reliably. So try to restart criu-damon every minute
* * * * * criu-daemon.sh
END
	crontab "$CRONTAB"
}

initialize() {
	local good_ref bad_ref

	load_config_and_handlers

	good_ref="$GOOD_COMMIT"
	bad_ref="$BAD_COMMIT"
	# Store original kernel in memory
	ORIGINAL_KERNEL=$(get_original_kernel)

	if [[ "$INSTALL_STRATEGY" == "rpm" ]]; then
		if [ ! -f "$KERNEL_RPM_LIST" ]; then do_abort "KERNEL_RPM_LIST file not found."; fi
		generate_git_repo_from_package_list
		good_ref=${release_commit_map[$GOOD_COMMIT]}
		bad_ref=${release_commit_map[$BAD_COMMIT]}
		if [ -z "$good_ref" ] || [ -z "$bad_ref" ]; then do_abort "Could not find GOOD/BAD versions in RPM list."; fi
	fi

	# Save resolved references in memory
	GOOD_REF="$good_ref"
	BAD_REF="$bad_ref"

	setup_criu
}

verify_intial_commits() {
	if [[ "$VERIFY_COMMITS" == "yes" ]]; then
		log "Skipping verifying initial commits"
		return 0
	fi

	log "Verifying initial GOOD commit"
	if ! commit_good "$GOOD_REF"; then
		do_abort "GOOD_COMMIT behaved as BAD"
	fi

	log "Verifying initial BAD commit"
	if commit_good "$BAD_REF"; then
		do_abort "BAD_COMMIT behaved as GOOD"
	fi
}

# --- Core Testing Functions ---
run_test() {
	# Wrapper for the actual test strategy
	run_test_strategy
	return $?
}

get_current_commit() {
	safe_cd "$GIT_REPO"
	git rev-parse HEAD
}

commit_good() {
	local commit="$1"
	log "Evaluating commit: $commit"

	run_install_strategy "$commit"
	run_reboot_strategy
	# Let the test handler manage multiple attempts and kernel panic
	# It will return 0 for GOOD, non-zero for BAD
	run_test
}

generate_final_report() {
	git bisect log >"$WORK_DIR/bisect_final_log.txt"
	log "Final report saved to $WORK_DIR/bisect_final_log.txt"
}
