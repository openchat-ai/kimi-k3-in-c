#!/bin/bash
# v31: --layer-bundle with the engine's own auto memory budget, against the hand-tuned
# 32 GB / 15 GB split that reached 73.96.
#
# Why this is the one path left. tools/verify_layer_bundle.sh says in its own header:
#   "Uses the AUTO memory budget (the engine hands spare RAM to the expert arena itself;
#    forcing --cache-gb starved it to 5 GB -> 0.34% TRUE hit)"
# Every run today forced --trunk-gb/--cache-gb by hand, which is the thing that comment
# warns about. --layer-bundle is also a different mechanism, not just a different split:
# plan_layer_bundles (k3_run.c) picks the resident layer set S by static footprint given a
# horizon (gen + prompt length), sized for the experts a layer is EXPECTED to touch, rather
# than pinning whatever fits in a byte budget. The planner prints its own plan, so the first
# thing to read is that line -- it is the first output of this experiment that has not been
# written by me.
#
# Controls (all clean build, same drive, same prompt):
#   today 73.96 s/token  hand-tuned  --trunk-gb 32 --cache-gb 15   (median of 3, spread 3.4%)
#   this run            planner's  --layer-bundle, auto budget
#
# Horizon here is gen 8 + 1 prompt token = 9 passes, the same horizon the 73.96 runs had,
# so any difference is the planner, not a longer lookahead.
set -u
cd /mnt/f/kimi-k3-in-c
OUT=/mnt/f/kimi-k3-in-c/reports/gateab_ab/v31_bundle
mkdir -p "$OUT"
LOG="$OUT/run-$(date +%Y%m%d_%H%M%S)"
mkdir -p "$LOG"
export K3_TRACE="$LOG/trace.csv"
unset K3_NOKIO K3_L2_NATIVE K3_IO_NW0
echo "--- before $(date +%T)  load=$(cut -d' ' -f1-3 /proc/loadavg)  MemAvail=$(awk '/MemAvailable/{printf "%.1fGB",$2/1048576}' /proc/meminfo)"
sync; echo 3 > /proc/sys/vm/drop_caches; sleep 2
/usr/bin/time -f "TIME_ELAPSED=%e" ./bin/k3 /model \
  --trunk /mnt/nvme/trunk_layers_out --embed-dir /mnt/nvme/embed \
  --layer-bundle \
  --ids 1008 --gen 8 --out "$LOG/ctrl.json" > "$LOG/ctrl.log" 2>&1
RC=$?
echo "EXIT=$RC  after $(date +%T)  load=$(cut -d' ' -f1-3 /proc/loadavg)"
{
  echo "--- v31_bundle (--layer-bundle, auto budget)"
  echo
  echo "== the planner's own plan (first output not written by me):"
  grep -aE "layer-bundle plan|auto budget|explicit" "$LOG/ctrl.log"
  echo
  grep -aE "PINNED|TRUE resident|s/token average|I/O share|experts, whole|phase2|pread\)|bind wall" "$LOG/ctrl.log" | tail -12
  grep -aE "^TIME_ELAPSED" "$LOG/ctrl.log"
  grep -aE "seconds_per_token|trunk_bytes_read|expert_bytes_read|peak_rss_bytes" "$LOG/ctrl.json"
} > "$LOG/summary.txt"
cat "$LOG/summary.txt"
echo "$LOG" > /root/last_trace_dir
echo "[v31] end $(date +%T)"