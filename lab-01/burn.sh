#!/bin/bash
# usage: burn.sh [seconds]   keeps every vCPU at 100% for that long (default 600)
SECS=${1:-600}
for i in $(seq "$(nproc)"); do timeout "$SECS" sh -c 'while :; do :; done' & done
wait
