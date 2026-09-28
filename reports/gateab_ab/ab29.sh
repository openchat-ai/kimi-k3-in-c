#!/bin/bash
# v29: clean re-measurement of the 68.54 s/token baseline, under BENCH_PROTO v1
# sections 6 and 7 (system left alone, load baseline recorded before and after).
#
# Why: v25 (68.54, 2026-09-28 12:21) is the day's only real result, and it was taken
# while the main session ran objdump, grep and builds against the same machine. It has no
# before/after load snapshot, so it cannot be shown to be free of that interference. This
# run uses the identical configuration and binary, with the operator idle, and records the
# baseline so the number is self-evidencing.
#
# Identical to v25: trunk 32 GB / cache 15 GB, K3_IO_NW0 unset (16 workers), no
# K3_L2_NATIVE, no prefetch, gen 8, ids 1008, clean build.
set -u
snap() {
  echo "--- baseline $1  $(date +%T)"
  echo "loadavg: $(cut -d' ' -f1-3 /proc/loadavg)"
  echo "MemAvailable: $(awk '/MemAvailable/{printf "%.1fGB",$2/1048576}' /proc/meminfo)"
  echo "MemFree:      $(awk '/MemFree/{printf "%.1fGB",$2/1048576}' /proc/meminfo)"
  echo "k3 procs:     $(pgrep -fc 'bin/k3' || echo 0)"
  echo "top procs:    $(ps -eo pcpu,comm --sort=-pcpu --no-headers | head -3 | tr '\n' ';')"
}
snap before
cd /mnt/f/kimi-k3-in-c
LOG=/mnt/f/kimi-k3-in-c/reports/gateab_ab/v29_clean-$(date +%Y%m%d_%H%M%S)
mkdir -p "$LOG"
export K3_TRACE="$LOG/trace.csv"
unset K3_NOKIO K3_L2_NATIVE K3_IO_NW0
echo "[ab29] $LOG trunk 32GB / cache 15GB, 16 workers, operator idle, baseline recorded"
sync; echo 3 > /proc/sys/vm/drop_caches; sleep 2
/usr/bin/time -f "TIME_ELAPSED=%e" ./bin/k3 /model \
  --trunk /mnt/nvme/trunk_layers_out --embed-dir /mnt/nvme/embed \
  --trunk-gb 32 --cache-gb 15 \
  --ids 1008 --gen 8 --out "$LOG/ctrl.json" > "$LOG/ctrl.log" 2>&1
RC=$?
snap after
echo "EXIT=$RC"
{
  echo "--- v29_clean (v25 repeat, operator idle, baseline recorded)"
  snap echo 2>/dev/null
  echo ""
  grep -aE "PINNED|TRUE resident|s/token average|I/O share|experts, whole|phase2|pread\)|bind wall" "$LOG/ctrl.log" | tail -12
  grep -aE "^TIME_ELAPSED" "$LOG/ctrl.log"
  grep -aE "seconds_per_token|trunk_bytes_read|expert_bytes_read" "$LOG/ctrl.json"
} > "$LOG/summary.txt"
cat "$LOG/summary.txt"
echo "$LOG" > /root/last_trace_dir
echo "[ab29] end $(date +%T)"