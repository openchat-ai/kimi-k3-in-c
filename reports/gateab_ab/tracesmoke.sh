#!/bin/bash
# Smoke-test the new K3_TRACE timeline: 2 tokens is enough to check the CSV shape and
# that trunk / expert / compute intervals line up. 1/4 the time of a full 8-token run.
set -u
cd /mnt/f/kimi-k3-in-c
LOG=/mnt/f/kimi-k3-in-c/reports/gateab_ab/trace_smoke-$(date +%Y%m%d_%H%M%S)
mkdir -p "$LOG"
export K3_TRACE="$LOG/trace.csv"
unset K3_NOKIO K3_L2_NATIVE
sync; echo 3 > /proc/sys/vm/drop_caches; sleep 2
/usr/bin/time -f "TIME_ELAPSED=%e" ./bin/k3 /model \
  --trunk /mnt/nvme/trunk_layers_out --embed-dir /mnt/nvme/embed \
  --trunk-gb 6 --cache-gb 40 \
  --ids 1008 --gen 2 --out "$LOG/ctrl.json" > "$LOG/ctrl.log" 2>&1
echo "EXIT=$?  trace=$LOG/trace.csv"
head -3 "$LOG/trace.csv"
echo "rows: $(wc -l < "$LOG/trace.csv")"
echo "$LOG" > /root/last_trace_dir