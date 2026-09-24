#!/bin/bash
pkill -f probe_duallane.py 2>/dev/null
pkill -f probe_duallane.sh 2>/dev/null
sleep 1
LOG=/mnt/f/kimi-k3-in-c/reports/probe_cold2_$(date +%Y%m%d_%H%M%S)
mkdir -p "$LOG"
nohup python3 -u /mnt/f/kimi-k3-in-c/reports/probe_cold2.py > "$LOG/result.txt" 2>&1 &
echo "launched $LOG $(date +%H:%M:%S)"