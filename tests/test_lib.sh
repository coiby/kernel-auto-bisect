#!/bin/bash
if [[ -z $TMT_PLAN_DATA ]]; then
    echo "TMT_PLAN_DATA not defined"
    exit 1
fi
XTRACE_LOG="${TMT_PLAN_DATA}/test.log"

