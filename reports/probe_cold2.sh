#!/bin/bash
LOG=/mnt/f/kimi-k3-in-c/reports/probe_cold2_$(date +%Y%m%d_%H%M%S)
mkdir -p "$LOG"
python3 -u /mnt/f/kimi-k3-in-c/reports/probe_cold2.py 2>&1 | tee "$LOG/result.txt"