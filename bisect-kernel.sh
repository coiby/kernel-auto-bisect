#!/bin/bash
#
# bisect-kernel.sh: Main orchestrator for reboot-based kernel bisection.
# Supports bisection from a git source tree or a list of RPMs.
#

set -e # Exit immediately if a command exits with a non-zero status.

# --- Configuration and State Files ---
CONFIG_FILE="/usr/local/bin/kdump-bisect/bisect.conf"
STATE_DIR="/var/local/kdump-bisect"
RESULT_FILE="${STATE_DIR}/result"
LOG_FILE="${STATE_DIR}/bisect.log"
STATE_FILE_PHASE="${STATE_DIR}/phase"
RUN_COUNT_FILE="${STATE_DIR}/run_count"
PANIC_FLAG_FILE="${STATE_DIR}/panic_flag"

# --- Load Config ---
if [ ! -f "$CONFIG_FILE" ]; then
    echo "FATAL: Config not found at ${CONFIG_FILE}" | tee -a "$LOG_FILE"
    exit 1
fi
source "$CONFIG_FILE"

# Associative array to map kernel releases to fake git commits
declare -A release_commit_map

# --- Logging ---
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"
}

# --- Kernel and Grub Management ---
get_installed_kernels() { grubby --info=ALL | grep -E "^kernel=" | sed 's/kernel=//;s/"//g'; }
set_boot_kernel() { log "Setting default boot kernel to: $1"; grubby --set-default "$1"; }
get_current_kernel_path() { grubby --info=/boot/vmlinuz-$(uname -r) | grep -E "^kernel=" | sed 's/kernel=//;s/"//g'; }

# --- Bisection Helper Functions ---
do_abort() {
    log "FATAL: $1"
    log "Aborting bisection."
    if [[ "$BISECT_MODE" == "git" ]]; then cd "$KERNEL_SRC_DIR"; git bisect reset || true; fi
    if [ -f "${STATE_DIR}/original_kernel" ]; then set_boot_kernel "$(cat "${STATE_DIR}/original_kernel")"; fi
    rm -rf "$STATE_DIR" "$RPM_FAKE_REPO_PATH"
    systemctl disable kdump-bisect.service
    exit 1
}

# --- RPM Mode Specific Functions ---
generate_git_repo_from_package_list() {
    log "Generating fake git repository for RPM list..."
    local _package_list="$KERNEL_RPM_LIST"
    local repo_path="$RPM_FAKE_REPO_PATH"

    if [[ -d "$repo_path" ]]; then rm -rf "$repo_path"; fi
    mkdir -p "$repo_path"; cd "$repo_path"

    git init -q
    git config user.name kernel-auto-bisect
    git config user.email kernel-auto-bisect@localhost

    touch kernel_url kernel_release
    git add kernel_url kernel_release
    git commit -m "init" >/dev/null

    while read -r _url; do
        echo "$_url" >kernel_url
        local _str=$(basename "$_url")
        _str=${_str#kernel-core-}
        local kernel_release=${_str%.rpm}
        echo "$kernel_release" >kernel_release
        git commit -m "$kernel_release" kernel_release kernel_url >/dev/null
        release_commit_map[$kernel_release]=$(git rev-parse HEAD)
    done <"$_package_list"
    log "Fake git repo created at ${repo_path}."
}

# --- Main Bisection Functions ---
do_start() {
    log "--- Bisection START ---"
    rm -rf "${STATE_DIR}" "$RPM_FAKE_REPO_PATH"
    mkdir -p "${STATE_DIR}"
    touch "$LOG_FILE"

    get_current_kernel_path > "${STATE_DIR}/original_kernel"

    local good_ref="$GOOD_COMMIT"
    local bad_ref="$BAD_COMMIT"

    if [[ "$BISECT_MODE" == "rpm" ]]; then
        if [ ! -f "$KERNEL_RPM_LIST" ]; then do_abort "KERNEL_RPM_LIST file not found: $KERNEL_RPM_LIST"; fi
        generate_git_repo_from_package_list
        good_ref=${release_commit_map[$GOOD_COMMIT]}
        bad_ref=${release_commit_map[$BAD_COMMIT]}
        if [ -z "$good_ref" ] || [ -z "$bad_ref" ]; then
            do_abort "Could not find GOOD/BAD commit versions in the RPM list. Check your config."
        fi
    fi

    # Store the resolved git references
    echo "$good_ref" > "${STATE_DIR}/good_ref"
    echo "$bad_ref" > "${STATE_DIR}/bad_ref"

    if [[ "$VERIFY_COMMITS" != "yes" ]]; then
        log "Verification skipped. Starting bisection directly."
        echo "BUILD" > "$STATE_FILE_PHASE"
    else
        log "Verification step enabled. Starting with GOOD commit."
        echo "VERIFY_GOOD_BUILD" > "$STATE_FILE_PHASE"
    fi
    
    handle_phase
}

do_install_commit() {
    local commit_to_install=$1
    local next_phase_on_reboot=$2
    local repo_dir
    local kernel_version_string

    if [[ "$BISECT_MODE" == "rpm" ]]; then
        log "--- Phase: INSTALL RPM for commit ${commit_to_install} ---"
        cd "$RPM_FAKE_REPO_PATH"
        git checkout -q "$commit_to_install"
        
        local core_url=$(cat kernel_url)
        local base_url=$(dirname "$core_url")
        local release=$(cat kernel_release)
        local arch=$(echo "$core_url" | rev | cut -d. -f2 | rev)

        local rpm_cache_dir="$RPM_CACHE_DIR"
        if [ -z "$rpm_cache_dir" ]; then do_abort "RPM_CACHE_DIR is not set in the configuration."; fi
        mkdir -p "$rpm_cache_dir"

        log "Ensuring RPMs for kernel ${release} are in cache: ${rpm_cache_dir}"
        local rpms_to_install=()
        for pkg in kernel-core kernel-modules kernel-modules-core kernel; do
            local rpm_filename="${pkg}-${release}.${arch}.rpm"
            local rpm_path="${rpm_cache_dir}/${rpm_filename}"
            local rpm_url="${base_url}/${rpm_filename}"

            if [ ! -f "$rpm_path" ]; then
                log "Downloading ${rpm_filename}..."
                if ! wget --no-check-certificate -q -O "$rpm_path" "$rpm_url"; then
                    rm -f "$rpm_path" # Cleanup partial download on failure
                    do_abort "Failed to download ${rpm_url}."
                fi
            else
                log "Found ${rpm_filename} in cache."
            fi
            rpms_to_install+=("$rpm_path")
        done

        log "Installing RPMs for ${release}"
        if ! dnf install -y "${rpms_to_install[@]}" > "${STATE_DIR}/install.log" 2>&1; then
            do_abort "Failed to install RPMs for ${release}."
        fi
        kernel_version_string="$release"
    else # git mode
        repo_dir="$KERNEL_SRC_DIR"
        log "--- Phase: BUILD for commit ${commit_to_install} ---"
        cd "$repo_dir"
        git checkout master; git clean -fdx
        git checkout -q "$commit_to_install"

        if ! make -j"${MAKE_JOBS}" > "${STATE_DIR}/build.log" 2>&1; then
            do_abort "Build failed for commit ${commit_to_install}."
        fi
        log "Installing kernel..."
        if ! make LOCALVERSION="${BISECT_VERSION_TAG}" modules_install install >> "${STATE_DIR}/build.log" 2>&1; then
            do_abort "Install failed for commit ${commit_to_install}."
        fi
        kernel_version_string="$(make -s kernelrelease)${BISECT_VERSION_TAG}"
    fi
    
    local new_kernel_path="/boot/vmlinuz-${kernel_version_string}"
    if [ ! -f "$new_kernel_path" ]; then
        do_abort "Installed kernel not found at ${new_kernel_path}."
    fi

    set_boot_kernel "$new_kernel_path"
    echo "$next_phase_on_reboot" > "$STATE_FILE_PHASE"
    log "Rebooting into new kernel..."
    reboot
}

do_bisect_install() {
    log "--- Phase: BUILD/INSTALL (Bisection) ---"
    local repo_dir
    if [[ "$BISECT_MODE" == "rpm" ]]; then repo_dir="$RPM_FAKE_REPO_PATH"; else repo_dir="$KERNEL_SRC_DIR"; fi
    cd "$repo_dir"

    if ! git bisect log > /dev/null 2>&1; then
        log "Verification complete. Starting git bisect process."
        git bisect reset || true
        if [[ "$BISECT_MODE" == "git" ]]; then git checkout master; git clean -fdx; fi
        git bisect start "$(cat ${STATE_DIR}/bad_ref)" "$(cat ${STATE_DIR}/good_ref)"
    fi

    local current_commit=$(git rev-parse HEAD)
    log "Processing bisect commit: ${current_commit}"
    
    # Re-use the main install function
    do_install_commit "$current_commit" "TEST"
}

do_test() {
    # This function remains largely the same, as it's mode-agnostic.
    # It just runs the user's functions and determines good/bad.
    log "--- Phase: TEST on $(uname -r) ---"

    if [ ! -f "$REPRODUCER_SCRIPT" ]; then do_abort "Reproducer script not found."; fi
    source "$REPRODUCER_SCRIPT"

    if [ ! -f "$RUN_COUNT_FILE" ]; then echo 1 > "$RUN_COUNT_FILE"; fi
    local run_count=$(cat "$RUN_COUNT_FILE")
    local current_phase=$(cat "$STATE_FILE_PHASE")

    if [ -f "$PANIC_FLAG_FILE" ]; then
        log "Verifying outcome of run #${run_count}"
        rm -f "$PANIC_FLAG_FILE"

        if ! type on_test &> /dev/null; then do_abort "'on_test' function not found."; fi
        if on_test; then local test_outcome="bad"; else local test_outcome="good"; fi

        if [[ "$current_phase" == "VERIFY_GOOD_TEST" ]]; then
            if [[ "$test_outcome" == "good" ]]; then
                log "SUCCESS: GOOD_COMMIT verified as good."
                echo "VERIFY_BAD_BUILD" > "$STATE_FILE_PHASE"
                do_return_and_continue
            else
                do_abort "GOOD_COMMIT behaved as BAD."
            fi
            return
        fi

        if [[ "$current_phase" == "VERIFY_BAD_TEST" ]]; then
            if [[ "$test_outcome" == "bad" ]]; then
                log "SUCCESS: BAD_COMMIT verified as bad."
                echo "BUILD" > "$STATE_FILE_PHASE"
                do_return_and_continue
            else
                do_abort "BAD_COMMIT behaved as GOOD."
            fi
            return
        fi
        
        if [[ "$test_outcome" == "bad" ]]; then
            log "SUCCESS: Commit is BAD."
            echo "bad" > "$RESULT_FILE"
            rm -f "$RUN_COUNT_FILE"
            do_return_and_continue
            return
        else
            log "FAILURE: on_test returned non-zero for run #${run_count}."
            if [ "$run_count" -ge "$RUNS_PER_COMMIT" ]; then
                log "All runs failed. Commit is GOOD."
                echo "good" > "$RESULT_FILE"
                rm -f "$RUN_COUNT_FILE"
                do_return_and_continue
                return
            fi
            run_count=$((run_count + 1)); echo "$run_count" > "$RUN_COUNT_FILE"
            log "Proceeding to run #${run_count}."
        fi
    fi

    log "Preparing to trigger panic for run #${run_count}."
    if ! type setup_test &> /dev/null; then do_abort "'setup_test' function not found."; fi
    log "Executing setup_test()..."
    if ! setup_test; then log "WARNING: setup_test() exited non-zero."; fi

    touch "$PANIC_FLAG_FILE"
    log "Triggering kernel panic NOW."
    echo 1 > /proc/sys/kernel/sysrq; echo c > /proc/sysrq-trigger
    log "ERROR: Failed to trigger panic! Rebooting in 3 minutes."; sleep 180; reboot
}

do_return_and_continue() {
    set_boot_kernel "$(cat "${STATE_DIR}/original_kernel")"
    if [[ "$(cat ${STATE_FILE_PHASE})" == "TEST" ]]; then
        echo "CONTINUE" > "$STATE_FILE_PHASE"
    fi
    log "Rebooting back to original kernel..."
    reboot
}

do_continue() {
    log "--- Phase: CONTINUE ---"
    local repo_dir
    if [[ "$BISECT_MODE" == "rpm" ]]; then repo_dir="$RPM_FAKE_REPO_PATH"; else repo_dir="$KERNEL_SRC_DIR"; fi
    cd "$repo_dir"

    if [ ! -f "$RESULT_FILE" ]; then do_abort "Result file not found!"; fi
    local result=$(cat "$RESULT_FILE"); rm -f "$RESULT_FILE"
    
    log "Test result was: ${result}. Advancing git bisect..."
    git bisect "$result" | tee "${STATE_DIR}/bisect_step.log"

    if grep -q "is the first bad commit" "${STATE_DIR}/bisect_step.log"; then
        log "--- BISECTION FINISHED ---"
        local final_report=$(git bisect log)
        if [[ "$BISECT_MODE" == "rpm" ]]; then
            local bad_commit_hash=$(echo "$final_report" | grep "first bad commit" | awk '{print $1}')
            git checkout -q "$bad_commit_hash"
            local bad_kernel_release=$(cat kernel_release)
            local bad_kernel_url=$(cat kernel_url)
            log "First bad kernel release: ${bad_kernel_release}"
            log "URL: ${bad_kernel_url}"
            echo -e "First bad kernel release: ${bad_kernel_release}\nURL: ${bad_kernel_url}" > "${STATE_DIR}/bisect_final_log.txt"
        else
            log "First bad commit found! See log for details."
            echo "$final_report" > "${STATE_DIR}/bisect_final_log.txt"
        fi
        do_abort "Bisection Complete. See final log in ${STATE_DIR}."
    fi

    echo "BUILD" > "$STATE_FILE_PHASE"
    do_bisect_install
}

handle_phase() {
    if [ ! -f "$STATE_FILE_PHASE" ]; then exit 0; fi
    local CURRENT_PHASE=$(cat "$STATE_FILE_PHASE")
    log "Detected phase: ${CURRENT_PHASE}"

    case "$CURRENT_PHASE" in
        VERIFY_GOOD_BUILD) do_install_commit "$(cat ${STATE_DIR}/good_ref)" "VERIFY_GOOD_TEST" ;;
        VERIFY_BAD_BUILD) do_install_commit "$(cat ${STATE_DIR}/bad_ref)" "VERIFY_BAD_TEST" ;;
        BUILD) do_bisect_install ;;
        TEST | VERIFY_GOOD_TEST | VERIFY_BAD_TEST)
            if [[ "$(uname -r)" != "$(basename $(cat ${STATE_DIR}/original_kernel))" ]]; then
                do_test
            else
                log "In a TEST phase but not on a test kernel. Waiting for reboot."
            fi
            ;;
        CONTINUE)
            if [[ "$(uname -r)" == "$(basename $(cat ${STATE_DIR}/original_kernel))" ]]; then
                do_continue
            else
                log "In CONTINUE phase but not on original kernel. Waiting for reboot."
            fi
            ;;
        *) log "Unknown phase: ${CURRENT_PHASE}. Doing nothing." ;;
    esac
}

# --- Main Entry Point ---
if [ -n "$1" ]; then
    [[ "$1" == "start" ]] && do_start || (log "Invalid command: $1"; exit 1)
else
    handle_phase
fi
