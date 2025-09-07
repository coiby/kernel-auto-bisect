#!/bin/bash
# Configuration
BIN_DIR=/usr/local/bin/kernel-auto-bisect
WORK_DIR="/var/local/kernel-auto-bisect"
SIGNAL_DIR="/var/run/kdump-bisect"
DUMP_DIR="$WORK_DIR/dump"
CHECKPOINT_SIGNAL="$SIGNAL_DIR/checkpoint_request"
RESTORE_FLAG="$SIGNAL_DIR/restore_flag"
PANIC_SIGNAL="$SIGNAL_DIR/panic_request"
LOG_FILE="/var/log/criu-daemon.log"
BISECT_SCRIPT="/usr/local/bin/kdump-bisect/bisect-kernel.sh"
