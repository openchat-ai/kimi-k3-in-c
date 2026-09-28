#!/bin/bash
# v25: v23's winning split (trunk 32 / cache 15) over 8 tokens WITH the trace on.
# Purpose is a single number the 2-token trace could not give: the STEADY-STATE
# arithmetic cost per token. The 2-token run span was 245 s, but token 0 carries the
# cold start, so its 38.3 s/token "pure compute" is an underestimate.
#
# What it decides. v23 moves 66.1 GB/token off the drive at 875 MB/s = 75.5 s of pure
# read time, yet the wall is 69.33 s -- so some read IS hidden and arithmetic sits below
# 69.33. How far below is exactly what this measures, and it is the ceiling any amount of
# extra RAM can buy: with every weight resident, the wall becomes the arithmetic.
#   arithmetic ~40 s  -> a 32 GB swap gets trunk fully resident and lands near 45
#   arithmetic ~60 s  -> more RAM buys little, 34 stays out of reach
#   arithmetic ~70 s+ -> RAM is nearly irrelevant; only faster arithmetic or fewer layers help
set -u
cd /mnt/f/kimi-k3-in-c
LOG=/mnt/f/kimi-k3-in-c/reports/gateab_ab/v25_trace8-$(date +%Y%m%d_%H%M%S)
mkdir -p "$LOG"
export K3_TRACE="$LOG/trace.csv"
unset K3_NOKIO K3_L2_NATIVE
echo "[ab25] start $(date +%T) mem=$(awk '/MemAvailable/{printf "%.1fGB",$2/1048576}' /proc/meminfo)"
echo "[ab25] $LOG trunk 32GB (22 layers) + cache 15GB, 8 tokens, trace on"
sync; echo 3 > /proc/sys/vm/drop_caches; sleep 2
/usr/bin/time -f "TIME_ELAPSED=%e" ./bin/k3 /model \
  --trunk /mnt/nvme/trunk_layers_out --embed-dir /mnt/nvme/embed \
  --trunk-gb 32 --cache-gb 15 \
  --ids 1008 --gen 8 --out "$LOG/ctrl.json" > "$LOG/ctrl.log" 2>&1
RC=$?
echo "EXIT=$RC"
{
  echo "--- v25_trace8 (trunk 32GB / cache 15GB, 8 tokens, trace on)"
  grep -aE "PINNED|TRUE resident|s/token average|I/O share|experts, whole|phase2|pread\)|bind wall|requests *:" "$LOG/ctrl.log" | tail -12
  grep -aE "^TIME_ELAPSED" "$LOG/ctrl.log"
  grep -aE "seconds_per_token|trunk_bytes_read|expert_bytes_read|peak_rss_bytes" "$LOG/ctrl.json"
} > "$LOG/summary.txt"
cat "$LOG/summary.txt"
echo "[ab25] trace rows: $(wc -l < "$LOG/trace.csv" 2>/dev/null || echo 0)"
echo "$LOG" > /root/last_trace_dir
echo "[ab25] end $(date +%T)"