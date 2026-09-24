#!/bin/bash
# dual-lane isolation bench, background wrapper
set -u
mkdir -p /mnt/nvme/var/probe_duallane
LOG=$(ls -dt /mnt/f/kimi-k3-in-c/reports/probe_duallane_20* 2>/dev/null | head -1)
if [ -z "$LOG" ]; then
  LOG="/mnt/f/kimi-k3-in-c/reports/probe_duallane_$(date +%Y%m%d_%H%M%S)"
  mkdir -p "$LOG"
fi
python3 -u /mnt/f/kimi-k3-in-c/reports/probe_duallane.py 2>&1 | tee "$LOG/result.txt"