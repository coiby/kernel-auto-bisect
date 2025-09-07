#!/bin/bash
#
# bisect-kernel.sh: Main orchestrator for reboot-based kernel bisection.
# Uses CRIU for state management instead of files, improving readability and reliability.
#
# Iterate over all open file descriptors for the current process
# --- Configuration ---
CONFIG_FILE="/usr/local/bin/kdump-bisect/bisect.conf"
HANDLER_DIR="/usr/local/bin/kdump-bisect/handlers"
LOG_FILE="/var/log/kdump-bisect.log"

# --- In-memory state variables (managed by CRIU) ---
LAST_TESTED_KERNEL=""
PANIC_OCCURRED=false
RUN_COUNT=1
ORIGINAL_KERNEL=""
GOOD_REF=""
BAD_REF=""

# --- Load Config and Handlers ---
load_config_and_handlers() {
    if [ ! -f "$CONFIG_FILE" ]; then echo "FATAL: Config file missing!" | tee -a "$LOG_FILE"; exit 1; fi
    source "$CONFIG_FILE"
    for handler in "${HANDLER_DIR}"/*.sh; do if [ -f "$handler" ]; then source "$handler"; fi; done
    rm -rf /var/local/kdump-bisect-criu/dump/*
    # 1. setsid somehow doesn't work, checkpointing will fail with "The criu itself is within dumped tree"
    #    setsid criu-daemon.sh < /dev/null &> log_file &
    # 2. Using a systemd service to start criu-daemon.sh somehow can lead to many
    #    dump/restore issues like "can't write lsm profile"
    systemd-run --unit=checkpoint-test /usr/local/bin/kdump-bisect/criu-daemon.sh
}

declare -A release_commit_map

# --- Logging ---
log() { echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" >> "$LOG_FILE"; }

# --- Kernel and Grub Management ---
set_boot_kernel() { log "Setting default boot kernel to: $1"; grubby --set-default "$1"; }

# --- CRIU Daemon Communication ---
SIGNAL_DIR="/var/run/kdump-bisect"
RESTORE_FLAG="$SIGNAL_DIR/restore_flag"
CHECKPOINT_SIGNAL="$SIGNAL_DIR/checkpoint_request"

signal_checkpoint_reboot() {
    mkdir -p "$SIGNAL_DIR"
    log "Signaling daemon to checkpoint and reboot"
    
    if [[ $1 == reboot ]]; then
       printf "sync\n systemctl reboot" > "$CHECKPOINT_SIGNAL"
    elif [[ $1 == panic ]]; then
       printf "sync\n echo 1 > /proc/sys/kernel/sysrq\n echo c > /proc/sysrq-trigger" > "$CHECKPOINT_SIGNAL"
    fi 

    # Wait for the daemon to process our request and reboot/panic the system
    # If we're still running after 10 seconds, something went wrong
    local count=0
    local MAX_WAIT=20
    while [[ -f "$RESTORE_FLAG" ]] && [[ $count -lt $MAX_WAIT ]]; do
        sleep 1
        count=$((count + 1))
    done
    
    if [[ $count -ge $MAX_WAIT ]]; then
        log "ERROR: Daemon failed to process checkpoint request"
        exit 1
    fi
}

signal_checkpoint_reboot() {
    signal_checkpoint "reboot"
}

signal_checkpoint_panic() {
    signal_checkpoint "panic"
}

prepare_reboot() {
    # try to reboot to current EFI bootloader entry next time
    command -v rstrnt-prepare-reboot &> /dev/null && rstrnt-prepare-reboot > /dev/null
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
        rpm) rpm -e "kernel-core-${kernel_to_remove}" > /dev/null 2>&1 || log "Failed to remove kernel RPMs.";;
        git) kernel-install remove ${kernel_to_remove}
             rm -rf /lib/modules/${kernel_to_remove} ;;
    esac
    LAST_TESTED_KERNEL=""
}

do_abort() {
    log "FATAL: $1"; log "Aborting bisection."
    if [[ "$INSTALL_STRATEGY" == "git" ]] && [ -d "$KERNEL_SRC_DIR" ]; then cd "$KERNEL_SRC_DIR"; git bisect reset || true; fi
    if [[ -n "$ORIGINAL_KERNEL" ]]; then
        log "Returning to original kernel."
        set_boot_kernel "$ORIGINAL_KERNEL"
    fi
    #remove_last_kernel
    #rm -rf "$RPM_FAKE_REPO_PATH"
    systemctl disable kdump-bisect.service
    log "To perform a full cleanup of all intermediate kernels, please do so manually."
    exit 1
}

# --- RPM Mode Specific Functions ---
generate_git_repo_from_package_list() {
    log "Generating fake git repository for RPM list..."
    local repo_path="$RPM_FAKE_REPO_PATH"; if [[ -d "$repo_path" ]]; then rm -rf "$repo_path"; fi
    mkdir -p "$repo_path"; cd "$repo_path"
    git init -q; git config user.name k; git config user.email k@l.c
    touch k_url k_rel; git add k_url k_rel; git commit -m "i" >/dev/null
    while read -r _url; do
        local _str=$(basename "$_url"); _str=${_str#kernel-core-}; local k_rel=${_str%.rpm}
        echo "$_url" >k_url; echo "$k_rel" >k_rel
        git commit -m "$k_rel" k_url k_rel >/dev/null
        release_commit_map[$k_rel]=$(git rev-parse HEAD)
    done <"$KERNEL_RPM_LIST"
}

# --- Core Testing Functions ---
run_test() {
    # Wrapper for the actual test strategy
    run_test_strategy
    return $?
}

test_commit() {
    local commit="$1"
    log "Testing commit: $commit"
    
    # Let the test handler manage multiple attempts and reboot cycles
    # It will return 0 for GOOD, non-zero for BAD
    run_test
}

commit_good() {
    local commit="$1"
    log "Evaluating commit: $commit"
    
    # Build and install the kernel for this commit
    run_install_strategy "$commit"
    run_reboot_strategy
    sleep 5
    
    # Test the commit (includes reboot cycle via CRIU daemon)
    test_commit "$commit"
}

# --- Main Bisection Functions ---
do_start() {
    # Clean up any previous CRIU state
    rm -rf  "$RPM_FAKE_REPO_PATH"
    touch "$LOG_FILE"

    log "--- Bisection START ---"

    # Store original kernel in memory
    ORIGINAL_KERNEL=$(grubby --info=/boot/vmlinuz-$(uname -r) | grep -E "^kernel=" | sed 's/kernel=//;s/"//g')

    local good_ref="$GOOD_COMMIT"; local bad_ref="$BAD_COMMIT"
    if [[ "$INSTALL_STRATEGY" == "rpm" ]]; then
        if [ ! -f "$KERNEL_RPM_LIST" ]; then do_abort "KERNEL_RPM_LIST file not found."; fi
        generate_git_repo_from_package_list
        good_ref=${release_commit_map[$GOOD_COMMIT]}; bad_ref=${release_commit_map[$BAD_COMMIT]}
        if [ -z "$good_ref" ] || [ -z "$bad_ref" ]; then do_abort "Could not find GOOD/BAD versions in RPM list."; fi
    fi

    # Save resolved references in memory
    GOOD_REF="$good_ref"
    BAD_REF="$bad_ref"

    # Initialize git bisect
    local repo_dir; if [[ "$INSTALL_STRATEGY" == "rpm" ]]; then repo_dir="$RPM_FAKE_REPO_PATH"; else repo_dir="$KERNEL_SRC_DIR"; fi
    cd "$repo_dir"
    
    # Verify initial commits if requested
    if [[ "$VERIFY_COMMITS" == "yes" ]]; then
        log "Verifying initial GOOD commit"
        if ! commit_good "$GOOD_REF"; then
            do_abort "GOOD_COMMIT behaved as BAD"
        fi
        
        log "Verifying initial BAD commit" 
        if commit_good "$BAD_REF"; then
            do_abort "BAD_COMMIT behaved as GOOD"
        fi
    fi
    
    # Start git bisect
    log "Starting git bisect process"
    git bisect start "$BAD_REF" "$GOOD_REF"
    
    # Check for adjacent commits (no bisection needed)
    if [[ $(git rev-list ${GOOD_REF}..${BAD_REF} | wc -l) -eq 1 ]]; then
        log "--- BISECTION FINISHED (Adjacent commits) ---"
        generate_final_report "$BAD_REF"
        do_abort "Bisection Complete"
    fi
    
    # Start main bisection loop
    main_bisect_loop
}

should_continue_bisect() {
    local repo_dir; if [[ "$INSTALL_STRATEGY" == "rpm" ]]; then repo_dir="$RPM_FAKE_REPO_PATH"; else repo_dir="$KERNEL_SRC_DIR"; fi
    cd "$repo_dir"
    
    # Check if git bisect is still ongoing
    git bisect log > /dev/null 2>&1
}

get_current_commit() {
    local repo_dir; if [[ "$INSTALL_STRATEGY" == "rpm" ]]; then repo_dir="$RPM_FAKE_REPO_PATH"; else repo_dir="$KERNEL_SRC_DIR"; fi
    cd "$repo_dir"
    git rev-parse HEAD
}

generate_final_report() {
    local bad_commit="$1"
    local final_report
    
    if [[ "$INSTALL_STRATEGY" == "rpm" ]]; then
        local repo_dir="$RPM_FAKE_REPO_PATH"
        cd "$repo_dir"
        git checkout -q "$bad_commit"
        final_report="Bad RPM found:\nRelease: $(cat k_rel)\nURL: $(cat k_url)"
    else
        final_report="First bad commit found:\nCommit: ${bad_commit}\n$(git log --oneline -1 $bad_commit)"
    fi
    
    echo -e "$final_report" > "/var/log/bisect_final_log.txt"
    log "Final report saved to /var/log/bisect_final_log.txt"
    echo -e "$final_report"
}

main_bisect_loop() {
    local repo_dir; if [[ "$INSTALL_STRATEGY" == "rpm" ]]; then repo_dir="$RPM_FAKE_REPO_PATH"; else repo_dir="$KERNEL_SRC_DIR"; fi
    cd "$repo_dir"
    
    while should_continue_bisect; do
        local commit=$(get_current_commit)
        log "--- Testing bisect commit: $commit ---"
        
        remove_last_kernel # Clean up previous kernel
        
        if commit_good "$commit"; then
            log "Marking commit as GOOD"
            local bisect_output=$(git bisect good "$commit")
        else
            log "Marking commit as BAD" 
            local bisect_output=$(git bisect bad "$commit")
        fi
        
        echo "$bisect_output"
        
        # Check if bisection is complete
        if echo "$bisect_output" | grep -q "is the first bad commit"; then
            log "--- BISECTION FINISHED ---"
            generate_final_report "$commit"
            finish
            return
        fi
    done
    
    log "Bisection loop ended unexpectedly"
    do_abort "Bisection incomplete"
}

finish() {
    remove_last_kernel
    set_boot_kernel "$ORIGINAL_KERNEL"
    reboot
    exit 0
}

# Note: process_result function removed - now handled directly in main_bisect_loop

# --- Main Entry Point ---
# Load configuration and handlers
load_config_and_handlers

# Start bisection - CRIU daemon handles any necessary restoration automatically
do_start
