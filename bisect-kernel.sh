#!/bin/bash
#
# bisect-kernel.sh: Main orchestrator for reboot-based kernel bisection.
# Implements a fast, unified state machine that avoids returning to the original kernel.
#

set -e # Exit immediately if a command exits with a non-zero status.

# --- Configuration and State Files ---
CONFIG_FILE="/usr/local/bin/kdump-bisect/bisect.conf"
STATE_DIR="/var/local/kdump-bisect"
HANDLER_DIR="/usr/local/bin/kdump-bisect/handlers"
LOG_FILE="${STATE_DIR}/bisect.log"
PLAN_FILE="${STATE_DIR}/plan.txt"
RESULT_FILE="${STATE_DIR}/result"
LAST_KERNEL_FILE="${STATE_DIR}/last_tested_kernel_version"
PANIC_FLAG_FILE="${STATE_DIR}/panic_flag"
RUN_COUNT_FILE="${STATE_DIR}/run_count"
ORIGINAL_KERNEL_FILE="${STATE_DIR}/original_kernel"
GOOD_REF_FILE="${STATE_DIR}/good_ref"
BAD_REF_FILE="${STATE_DIR}/bad_ref"

# --- Load Config and Handlers ---
if [ -d "$STATE_DIR" ]; then
    if [ ! -f "$CONFIG_FILE" ]; then echo "FATAL: State dir exists but config is missing!" | tee -a "$LOG_FILE"; exit 1; fi
    source "$CONFIG_FILE"
    for handler in "${HANDLER_DIR}"/*.sh; do if [ -f "$handler" ]; then source "$handler"; fi; done
fi

declare -A release_commit_map

# --- Logging ---
log() { echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"; }

# --- Kernel and Grub Management ---
set_boot_kernel() { log "Setting default boot kernel to: $1"; grubby --set-default "$1"; }

# --- Bisection Helper Functions ---
preapre_reboot() {
    # try to reboot to current EFI bootloader entry next time
    command -v rstrnt-prepare-reboot &> /dev/null && rstrnt-prepare-reboot > /dev/null
    sync
}

remove_last_kernel() {
    # This function is now only called during do_abort to clean up the final state.
    if [ ! -f "$LAST_KERNEL_FILE" ]; then return; fi
    local kernel_to_remove=$(cat "$LAST_KERNEL_FILE")
    # Safety check: never remove the original kernel
    if [[ -z "$kernel_to_remove" ]] || [[ "/boot/vmlinuz-$(uname -r)" == "$(cat "$ORIGINAL_KERNEL")" ]]; then
        log "WARNING: Skipping removal of last kernel, as it is running or undefined."
        rm -f "$LAST_KERNEL_FILE"
        return
    fi
    log "Cleaning up last tested kernel: ${kernel_to_remove}"
    case "$INSTALL_STRATEGY" in
        rpm) rpm -e "kernel-core-${kernel_to_remove}" > /dev/null 2>&1 || log "Failed to remove kernel RPMs.";;
        git) kernel-install remove ${kernel_to_remove}
             rm -rf /lib/modules/${kernel_to_remove} ;;
    esac
    rm -f "$LAST_KERNEL_FILE"
}

do_abort() {
    log "FATAL: $1"; log "Aborting bisection."
    if [[ "$INSTALL_STRATEGY" == "git" ]] && [ -d "$KERNEL_SRC_DIR" ]; then cd "$KERNEL_SRC_DIR"; git bisect reset || true; fi
    if [ -f "$ORIGINAL_KERNEL_FILE" ]; then
        log "Returning to original kernel."
        set_boot_kernel "$(cat "$ORIGINAL_KERNEL_FILE")"
    fi
    #remove_last_kernel
    #rm -rf "$STATE_DIR" "$RPM_FAKE_REPO_PATH"
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

# --- Main Bisection Functions ---
do_start() {
    if [[ -d ${STATE_DIR} ]]; then
        echo "${STATE_DIR} exists, deleting it"
    fi
    rm -rf "${STATE_DIR}" "$RPM_FAKE_REPO_PATH"
    mkdir -p "${STATE_DIR}"
    touch "$LOG_FILE"

    log "--- Bisection START ---"

    grubby --info=/boot/vmlinuz-$(uname -r) | grep -E "^kernel=" | sed 's/kernel=//;s/"//g' > "$ORIGINAL_KERNEL_FILE"

    local good_ref="$GOOD_COMMIT"; local bad_ref="$BAD_COMMIT"
    if [[ "$INSTALL_STRATEGY" == "rpm" ]]; then
        if [ ! -f "$KERNEL_RPM_LIST" ]; then do_abort "KERNEL_RPM_LIST file not found."; fi
        generate_git_repo_from_package_list
        good_ref=${release_commit_map[$GOOD_COMMIT]}; bad_ref=${release_commit_map[$BAD_COMMIT]}
        if [ -z "$good_ref" ] || [ -z "$bad_ref" ]; then do_abort "Could not find GOOD/BAD versions in RPM list."; fi
    fi

    # Save resolved references for later use.
    echo "$good_ref" > "$GOOD_REF_FILE"
    echo "$bad_ref" > "$BAD_REF_FILE"

    if [[ "$VERIFY_COMMITS" == "yes" ]]; then
        echo "VERIFY_GOOD:$good_ref" > "$PLAN_FILE"
        echo "VERIFY_BAD:$bad_ref" >> "$PLAN_FILE"
    fi
    echo "BISECT" >> "$PLAN_FILE"
    
    decide_next_action
}

decide_next_action() {
    log "--- Phase: DECIDE_NEXT_ACTION ---"
    if [ ! -s "$PLAN_FILE" ]; then do_abort "Plan is empty but bisection not finished."; fi
    
    local current_task=$(head -n 1 "$PLAN_FILE"); local task_type=$(echo "$current_task" | cut -d: -f1)
    local commit_to_test

    case "$task_type" in
        VERIFY_GOOD|VERIFY_BAD)
            commit_to_test=$(echo "$current_task" | cut -d: -f2) ;;
        BISECT)
            local repo_dir; if [[ "$INSTALL_STRATEGY" == "rpm" ]]; then repo_dir="$RPM_FAKE_REPO_PATH"; else repo_dir="$KERNEL_SRC_DIR"; fi
            cd "$repo_dir"
            if ! git bisect log > /dev/null 2>&1; then
                # This is the first time we enter the BISECT task.
                # If verification was enabled, we can check for the edge case here.
                if [[ "$VERIFY_COMMITS" == "yes" ]]; then
                    local good_ref=$(cat "$GOOD_REF_FILE")
                    local bad_ref=$(cat "$BAD_REF_FILE")
                    # If there's only one commit in the range, we've already found the culprit.
                    if [[ $(git rev-list ${good_ref}..${bad_ref} | wc -l) -eq 1 ]]; then
                        log "--- BISECTION FINISHED (Pre-check) ---"
                        local final_report
                        if [[ "$INSTALL_STRATEGY" == "rpm" ]]; then
                            git checkout -q "$bad_ref"
                            final_report="Bad RPM is adjacent to Good RPM. First bad RPM found:\nRelease: $(cat k_rel)\nURL: $(cat k_url)"
                        else
                            final_report="The provided BAD_COMMIT is the first bad commit after GOOD_COMMIT.\nCommit: ${bad_ref}"
                        fi
                        echo -e "$final_report" > "${STATE_DIR}/bisect_final_log.txt"; do_abort "Bisection Complete."
                    fi
                fi

                log "Starting git bisect process."
                git bisect start "$(cat $BAD_REF_FILE)" "$(cat $GOOD_REF_FILE)"
            fi
            commit_to_test=$(git rev-parse HEAD) ;;
        *) do_abort "Unknown task in plan: ${current_task}" ;;
    esac

    log "Next task is to install commit ${commit_to_test}"
    run_install_strategy "$commit_to_test"
    run_reboot_strategy
}

finish() {
    remove_last_kernel
    set_boot_kernel "$(cat "$ORIGINAL_KERNEL")"
    reboot
    exit 0
}

process_result() {
    log "--- Phase: PROCESS_RESULT ---"
    if [ ! -f "$RESULT_FILE" ]; then do_abort "Result file not found!"; fi
    local result=$(cat "$RESULT_FILE"); rm -f "$RESULT_FILE"
    local current_task=$(head -n 1 "$PLAN_FILE"); local task_type=$(echo "$current_task" | cut -d: -f1)
    local run_count=$(cat "$RUN_COUNT_FILE" 2>/dev/null || echo 1)

    case "$task_type" in
        VERIFY_GOOD)
            if [[ "$result" == "bad" ]]; then do_abort "GOOD_COMMIT behaved as BAD."; fi
            if [ "$run_count" -ge "$RUNS_PER_COMMIT" ]; then
                log "SUCCESS: GOOD_COMMIT verified."; sed -i '1d' "$PLAN_FILE"; rm -f "$RUN_COUNT_FILE"
            else echo $((run_count+1)) > "$RUN_COUNT_FILE"; fi
            ;;
        VERIFY_BAD)
            if [[ "$result" == "bad" ]]; then
                log "SUCCESS: BAD_COMMIT verified as bad."
                sed -i '1d' "$PLAN_FILE"; rm -f "$RUN_COUNT_FILE"
            elif [ "$run_count" -ge "$RUNS_PER_COMMIT" ]; then do_abort "BAD_COMMIT behaved as GOOD.";
            else echo $((run_count+1)) > "$RUN_COUNT_FILE"; fi
            ;;
        BISECT)
            local repo_dir; if [[ "$INSTALL_STRATEGY" == "rpm" ]]; then repo_dir="$RPM_FAKE_REPO_PATH"; else repo_dir="$KERNEL_SRC_DIR"; fi; cd "$repo_dir"
            if [[ "$result" == "bad" ]] || [ "$run_count" -ge "$RUNS_PER_COMMIT" ]; then
                local bisect_result=$([[ "$result" == "bad" ]] && echo "bad" || echo "good")
                log "Test conclusive. Updating git bisect with '${bisect_result}'"
                git bisect "$bisect_result" | tee "${STATE_DIR}/bisect_step.log"
                rm -f "$RUN_COUNT_FILE"
                if grep -q "is the first bad commit" "${STATE_DIR}/bisect_step.log"; then
                    log "--- BISECTION FINISHED ---"; local final_report=$(git bisect log)
                    if [[ "$INSTALL_STRATEGY" == "rpm" ]]; then
                        local bad_hash=$(echo "$final_report"|grep "bad"|head -n 1|awk '{print $1}'); git checkout -q "$bad_hash"
                        final_report="Bad RPM: $(cat k_rel)\nURL: $(cat k_url)"
                    fi
                    echo -e "$final_report" > "${STATE_DIR}/bisect_final_log.txt"; do_abort "Bisection Complete."
                    finish
                fi
            else echo $((run_count+1)) > "$RUN_COUNT_FILE"; fi
            ;;
    esac
    decide_next_action
}

# --- Main Entry Point ---
if [ ! -d "$STATE_DIR" ]; then
    if [ ! -f "$CONFIG_FILE" ]; then echo "Config file not found. Cannot start."; exit 1; fi
    source "$CONFIG_FILE"
    # Source handlers for the first time on a clean run
    for handler in "${HANDLER_DIR}"/*.sh; do if [ -f "$handler" ]; then source "$handler"; fi; done
    do_start
else
    # Every boot after the first is now considered a test environment boot.
    run_test_strategy
fi
