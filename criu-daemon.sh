#!/bin/bash
#
# criu-daemon.sh: External daemon for managing CRIU checkpoint/restore and reboots
# This daemon runs independently and handles the checkpoint → reboot → restore cycle
#

set -x
single_instance_lock()
{
    local _lockfile

    _lockfile=/run/lock/kernel-auto-bisect-criu.lock

    EXEC_FD=200

    if ! exec 200> $_lockfile; then
        derror "Create file lock failed"
        exit 1
    fi

    flock -n "$EXEC_FD" || {
        echo "ERROR: An instance of the script is already running." >&2
            exit 1
        }
}

single_instance_lock

# Configuration
WORK_DIR="/var/local/kdump-bisect-criu"
SIGNAL_DIR="/var/run/kdump-bisect"
DUMP_DIR="$WORK_DIR/dump"
CHECKPOINT_SIGNAL="$SIGNAL_DIR/checkpoint_request"
RESTORE_SIGNAL="$SIGNAL_DIR/restore_request" 
PANIC_SIGNAL="$SIGNAL_DIR/panic_request"
LOG_FILE="/var/log/criu-daemon.log"
BISECT_SCRIPT="/usr/local/bin/kdump-bisect/bisect-kernel.sh"

# Logging
log() { 
    echo "$(date '+%Y-%m-%d %H:%M:%S') [CRIU-DAEMON] - $1" | tee -a "$LOG_FILE"
}

# Initialize
init_daemon() {
    mkdir -p "$WORK_DIR" "$DUMP_DIR" "$SIGNAL_DIR"
    log "CRIU daemon started, monitoring for signals"
}

# Find the bisection process PID
find_bisect_pid() {
    pgrep -f "$BISECT_SCRIPT" | head -n1
}

# Checkpoint the bisection process
do_checkpoint() {
    local bisect_pid=$(find_bisect_pid)
    if [[ -z "$bisect_pid" ]]; then
        log "ERROR: No bisection process found to checkpoint"
        return 1
    fi
    
    log "Checkpointing bisection process (PID: $bisect_pid)"
    log_num=$(ls -l $WORK_DIR/dump*.log 2> /dev/null |wc -l)
    ((++log_num))
    dump_log=$WORK_DIR/dump${log_num}.log
    cmd_log=$WORK_DIR/dump${log_num}_cmd.log
    if criu dump -t "$bisect_pid" -D "$DUMP_DIR" -v4 -o $dump_log &> $cmd_log; then
        log "Checkpoint successful"
        return 0
    else
	rm -rf "$DUMP_DIR"/*
        log "ERROR: Checkpoint failed"
        return 1
    fi
}

# Restore the bisection process
do_restore() {
    if [ -d "$DUMP_DIR" ] && ls "$DUMP_DIR"/core-*.img 1> /dev/null 2>&1; then
        log "Restoring bisection process from checkpoint"
        # prevent "PID mismatch on restore" https://criu.org/When_C/R_fails
        unshare -p -m --fork --mount-proc

        log_num=$(ls -l $WORK_DIR/restore*.log 2> /dev/null |wc -l)
        ((++log_num))
        restore_log=$WORK_DIR/retore${log_num}.log
        cmd_log=$WORK_DIR/retore${log_num}_cmd.log
        if criu restore -v4 -D "$DUMP_DIR" --shell-job --restore-detached -o $restore_log &> $cmd_log ;  then
            log "Restore successful"
            # Clean up checkpoint files after successful restore
            rm -rf "$DUMP_DIR"/*
	    sync
            return 0
        else
            log "ERROR: Restore failed"
            return 1
        fi
    else
        log "No checkpoint found to restore"
        return 1
    fi
}

# Handle checkpoint + reboot request
handle_checkpoint_reboot() {
    log "Received checkpoint+reboot request"
    if do_checkpoint; then
        log "Initiating system reboot"
        sleep 2  # Give some time for the log to be written
	sync
        reboot
    else
        log "Checkpoint failed, aborting reboot"
        rm -f "$CHECKPOINT_SIGNAL"
    fi
}

# Handle checkpoint + panic request  
handle_checkpoint_panic() {
    log "Received checkpoint+panic request"
    if do_checkpoint; then
        log "Triggering kernel panic"
        sleep 2  # Give some time for the log to be written
	sync
        echo 1 > /proc/sys/kernel/sysrq
        echo c > /proc/sysrq-trigger
        # Fallback if panic fails
        sleep 10
        log "Panic failed, falling back to reboot"
        reboot
    else
        log "Checkpoint failed, aborting panic"
        rm -f "$PANIC_SIGNAL"
    fi
}

# Handle restore request (called on boot)
handle_restore() {
    log "Received restore request"
    if do_restore; then
        log "Process restored successfully"
    else
        log "Restore failed or no checkpoint available"
    fi
    rm -f "$RESTORE_SIGNAL"
}

# Main daemon loop
main_loop() {
    while true; do
        if [[ -f "$CHECKPOINT_SIGNAL" ]]; then
            handle_checkpoint_reboot
            rm -f "$CHECKPOINT_SIGNAL"
        elif [[ -f "$PANIC_SIGNAL" ]]; then
            handle_checkpoint_panic
            rm -f "$PANIC_SIGNAL"
        elif [[ -f "$RESTORE_SIGNAL" ]]; then
            handle_restore
        fi
        
        sleep 1
    done
}

# Handle script arguments
case "${1:-daemon}" in
    daemon)
        init_daemon
        if  [ -d "$DUMP_DIR" ] && ls "$DUMP_DIR"/core-*.img 1> /dev/null 2>&1; then
            log "Found checkpoint on boot, restoring"
            (do_restore) &
        fi
        main_loop
        ;;
    restore)
        # Called by systemd on boot to restore any existing checkpoint
        init_daemon
        ;;
    *)
        echo "Usage: $0 [daemon|restore]"
        exit 1
        ;;
esac
