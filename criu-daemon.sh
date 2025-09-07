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
source /usr/local/bin/kernel-auto-bisect/lib.sh


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
    log_num=$(ls -l $WORK_DIR/dump*_cmd.log 2> /dev/null |wc -l)
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

        log_num=$(ls -l $WORK_DIR/restore*_cmd.log 2> /dev/null |wc -l)
        ((++log_num))
        restore_log=$WORK_DIR/retore${log_num}.log
        cmd_log=$WORK_DIR/retore${log_num}_cmd.log
        if criu restore -v4 -D "$DUMP_DIR" --shell-job --restore-detached -o $restore_log &> $cmd_log ;  then
            log "Restore successful"
            # Clean up checkpoint files after successful restore
            rm -rf "$DUMP_DIR"/*
            touch "$RESTORE_FLAG"
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

# Handle checkpoint  
handle_checkpoint() {
    log "Received checkpoint+panic request"
    if ! grep -e sysrq-trigger -e reboot "$CHECKPOINT_SIGNAL"; then
        return 1
    fi
    if do_checkpoint; then
        log "Process request: $(< $CHECKPOINT_SIGNAL)"
        bash "$CHECKPOINT_SIGNAL"
        exit 0
    else
        log "Checkpoint failed"
        rm -f "$CHECKPOINT_SIGNAL"
    fi
}

# Main daemon loop
main_loop() {
    while true; do
        if [[ -f "$CHECKPOINT_SIGNAL" ]]; then
            handle_checkpoint
        fi
        sleep 1
    done
}

rm -f "$CHECKPOINT_SIGNAL"
init_daemon
(do_restore) &
main_loop
