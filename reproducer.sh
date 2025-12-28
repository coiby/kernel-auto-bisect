#!/bin/bash
#
# Reproducer script with setup and verification functions.
# This script is sourced by bisect-kernel.sh, not executed directly.
#

#
# setup_test()
#
# This function is called BEFORE the kernel panic is triggered.
# Use it to load modules, mount filesystems, start services,
# or do anything else required to get the system into a state
# where the bug can be triggered.
#
setup_test() {
    echo "REPRODUCER: Running setup_test..."
    # Example: Load a specific kernel module needed for the test
    # modprobe my_buggy_driver
    
    # Example: Create a specific file or configuration
    # echo "options my_buggy_driver mode=1" > /etc/modprobe.d/test.conf

    echo "REPRODUCER: Setup complete."
    # Return 0 for success. A non-zero return will be logged as a warning.
    return 0
}


#
# on_test()
#
# This function is called AFTER the system has panicked and rebooted.
# Use it to check if the bad condition occurred.
#
# EXIT CODES ARE CRITICAL:
#   - exit 1: The commit is BAD (test fails).
#   - exit 0: The commit is GOOD (test succeeds).
#
on_test() {
    echo "REPRODUCER: Running on_test for verification..."

    # Example: Check if a vmcore was created. This is a robust way to check for
    # a new vmcore. It looks for a crash directory newer than the state
    # directory, which is touched right before the panic.
    local crash_dir
    crash_dir=$(grep '^path ' /etc/kdump.conf | awk '{print $2}')
    [ -z "$crash_dir" ] && crash_dir="/var/crash"
    local state_dir_for_timestamp="/var/local/kdump-bisect"

    local latest_dump
    latest_dump=$(find "$crash_dir" -mindepth 1 -maxdepth 1 -type d -newer "$state_dir_for_timestamp" -print -quit)

    if [ -n "$latest_dump" ] && [ -f "${latest_dump}/vmcore" ]; then
        echo "REPRODUCER: SUCCESS. New vmcore found at ${latest_dump}."
        # Clean up the crash dump so it's not found on the next run
        rm -rf "${latest_dump}"
        return 0 # GOOD commit
    else
        echo "REPRODUCER: FAILURE. No new vmcore file found."
        return 1 # BAD commit
    fi
}
