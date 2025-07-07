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

    # This loop will continue as long as tests are inconclusive and we have retries.
    # For panic mode, each iteration involves a reboot.
    while true; do
        local run_count=$(cat "$RUN_COUNT_FILE")

        if [ -f "$PANIC_FLAG_FILE" ]; then
            # This boot is for VERIFYING a previous panic
            log "Verifying outcome of run #${run_count}"; rm -f "$PANIC_FLAG_FILE"
            if ! type on_test &> /dev/null; then do_abort "'on_test' function not found."; fi

            # on_test returning 0 means GOOD. Non-zero means BAD.
            if ! on_test; then
                log "Test was bad on run #${run_count}. Marking commit as bad."
                echo "bad" > "$RESULT_FILE"
                process_result # Conclusive result, process it.
                exit 0
            fi

            # Test was good, which is inconclusive. Check if we should retry.
            log "Test run #${run_count} was good (inconclusive)."
            if [ "$run_count" -ge "$RUNS_PER_COMMIT" ]; then
                log "All ${RUNS_PER_COMMIT} runs were good. Marking commit as conclusively good."
                echo "good" > "$RESULT_FILE"
                process_result # Conclusive result, process it.
                exit 0
            fi
            
            # We have retries left, so we will fall through to trigger the panic again.
            run_count=$((run_count + 1))
            echo $run_count > "$RUN_COUNT_FILE"
            log "Proceeding to run attempt #${run_count}."
        fi

        # This logic is reached on the first run, or after an inconclusive run.
        log "Preparing to trigger panic for run #${run_count}."
        if ! type setup_test &> /dev/null; then do_abort "'setup_test' function not found for panic mode."; fi
        if ! setup_test; then log "WARNING: setup_test() exited non-zero."; fi
        
        local count=0
        while : ; do
            kdumpctl status && break
            sleep 5
            count=$((count + 5))
            if [[ $count -gt 60 ]]; then
                do_abort "kdump service not ready after 60s. Aborting."
            fi
        done

        touch "$PANIC_FLAG_FILE"; log "Triggering kernel panic NOW."
        preapre_reboot
        echo 1 > /proc/sys/kernel/sysrq; echo c > /proc/sysrq-trigger
        log "ERROR: Failed to trigger panic! Rebooting in 3 minutes."; sleep 180; reboot
    done
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

