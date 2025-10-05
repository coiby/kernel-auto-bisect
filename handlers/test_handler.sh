#!/bin/bash
#
# test_handler.sh: Contains strategies for running tests.
# This version implements the "fast reboot" logic by calling process_result directly.
#

run_test_strategy() {
    log "--- Phase: RUN_TEST on $(uname -r) ---"
    [[ -z $RUNS_PER_COMMIT ]] && RUNS_PER_COMMIT=1
    case "$TEST_STRATEGY" in
        panic)  run_panic_test ;;
        simple) run_simple_test ;;
        *)      do_abort "Unknown TEST_STRATEGY: ${TEST_STRATEGY}" ;;
    esac
}

run_panic_test() {
    if [ ! -f "$REPRODUCER_SCRIPT" ]; then do_abort "Reproducer script not found."; fi
    source "$REPRODUCER_SCRIPT"

    RUN_COUNT=0
    # This loop will continue as long as tests are inconclusive and we have retries.
    # For panic mode, each iteration involves a reboot.
    while true; do
        if $PANIC_OCCURRED; then
            # This boot is for VERIFYING a previous panic
            log "Verifying outcome of run #${RUN_COUNT}"
            PANIC_OCCURRED=false
            if ! type on_test &> /dev/null; then do_abort "'on_test' function not found."; fi

            # on_test returning 0 means GOOD. Non-zero means BAD.
            if ! on_test; then
                log "Test was bad on run #${RUN_COUNT}. Marking commit as bad."
                return 1 # BAD
            fi

            # Test was good, which is inconclusive. Check if we should retry.
            log "Test run #${RUN_COUNT} was good (inconclusive)."
            if [ "$RUN_COUNT" -ge "$RUNS_PER_COMMIT" ]; then
                log "All ${RUNS_PER_COMMIT} runs were good. Marking commit as conclusively good."
                return 0 # GOOD
            fi
            
            # We have retries left, so we will fall through to trigger the panic again.
            RUN_COUNT=$((RUN_COUNT + 1))
            log "Proceeding to run attempt #${RUN_COUNT}."
        fi

        # This logic is reached on the first run, or after an inconclusive run.
        log "Preparing to trigger panic for run #${RUN_COUNT}."
        if ! type setup_test &> /dev/null; then log "'setup_test' function not found for panic mode."; fi
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

        PANIC_OCCURRED=true
        log "Triggering kernel panic NOW."
        prepare_reboot
        signal_checkpoint_panic
    done
}

run_simple_test() {
    if [ ! -f "$REPRODUCER_SCRIPT" ]; then do_abort "Reproducer script not found."; fi
    source "$REPRODUCER_SCRIPT"
    if ! type on_test &> /dev/null; then do_abort "'on_test' function not found for simple mode."; fi
    
    log "Running simple test..."
    
    # on_test returning 0 means GOOD. Non-zero means BAD.
    if on_test; then
        log "Simple test passed - commit is GOOD"
        return 0 # GOOD
    else
        log "Simple test failed - commit is BAD"
        return 1 # BAD
    fi
}

