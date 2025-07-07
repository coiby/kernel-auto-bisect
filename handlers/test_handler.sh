#!/bin/bash
#
# test_handler.sh: Contains strategies for running tests.
# This version implements the "fast reboot" logic by calling process_result directly.
#

run_test_strategy() {
    log "--- Phase: RUN_TEST on $(uname -r) ---"
    case "$TEST_STRATEGY" in
        panic)  run_panic_test ;;
        simple) run_simple_test ;;
        *)      do_abort "Unknown TEST_STRATEGY: ${TEST_STRATEGY}" ;;
    esac
}

run_panic_test() {
    if [ ! -f "$REPRODUCER_SCRIPT" ]; then do_abort "Reproducer script not found."; fi
    source "$REPRODUCER_SCRIPT"
    if [ ! -f "$RUN_COUNT_FILE" ]; then echo 1 > "$RUN_COUNT_FILE"; fi
    local run_count=$(cat "$RUN_COUNT_FILE")

    if [ -f "$PANIC_FLAG_FILE" ]; then
        # This boot is for VERIFYING a previous panic
        log "Verifying outcome of run #${run_count}"; rm -f "$PANIC_FLAG_FILE"
        if ! type on_test &> /dev/null; then do_abort "'on_test' function not found."; fi
        
        # on_test returning 0 means GOOD.
        if on_test; then
            echo "good" > "$RESULT_FILE"
        else
            echo "bad" > "$RESULT_FILE"
        fi
        
        # CRITICAL FIX: After a test is conclusive, immediately process the result
        # on the current kernel. This avoids rebooting back to the original one.
        process_result
        
        # The process_result function will handle the next reboot, so we exit here.
        exit 0
    fi

    # This boot is for SETTING UP and TRIGGERING a panic
    log "Preparing to trigger panic for run #${run_count}."
    if ! type setup_test &> /dev/null; then do_abort "'setup_test' function not found for panic mode."; fi
    if ! setup_test; then log "WARNING: setup_test() exited non-zero."; fi
    preapre_reboot

    while : ; do
        kdumpctl status && break
        sleep 5
        count=$((count + 5))
        if [[ $count -gt 60 ]]; then
            do_abort "Something is wrong. Please fix it and trigger panic manually"
        fi
    done

    touch "$PANIC_FLAG_FILE"; log "Triggering kernel panic NOW."
    echo 1 > /proc/sys/kernel/sysrq; echo c > /proc/sysrq-trigger
    log "ERROR: Failed to trigger panic! Rebooting in 3 minutes."; sleep 180; reboot
}

run_simple_test() {
    if [ ! -f "$REPRODUCER_SCRIPT" ]; then do_abort "Reproducer script not found."; fi
    source "$REPRODUCER_SCRIPT"
    if ! type on_test &> /dev/null; then do_abort "'on_test' function not found for simple mode."; fi
    
    log "Running simple test..."
    
    # on_test returning 0 means GOOD.
    if on_test; then echo "good" > "$RESULT_FILE"; else echo "bad" > "$RESULT_FILE"; fi
    
    # Since there's no reboot, we immediately move to process the result.
    process_result
    exit 0
}

