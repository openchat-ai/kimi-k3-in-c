#!/bin/bash
# ab22: --prefetch-depth 1 on a CLEAN build, with the timeline trace on.
#
# The only prefetch number we have (128.69 s/tok) was measured against the stale-objectfile
# binary whose matmul kernels had degraded to 128-bit SSE, so it proves nothing. And the
# trace shows why it might work at all: each layer reads 16 expert slots (280.89 MB) whose
# L2 copies it then uses immediately, while the L1 arena (2278 slots) cannot hold two
# tokens' working set (2706 needed) and re-reads 14.6% of it. Prefetching the PREVIOUS
# token's routing of layer L+1 moves that read off the critical path and, if the slot is
# still resident when the layer is reached, off the disk entirely.
#
# What the trace will show, per token: whether the expert interval now sits inside the
# compute interval (hidden) or before it (exposed), the L2/L1 split, and evictions.
set -u
cd /mnt/f/kimi-k3-in-c
LOG=/mnt/f/kimi-k3-in-c/reports/gateab_ab/v22_pf1-$(date +%Y%m%d_%H%M%S)
mkdir -p "$LOG"
export K3_TRACE="$LOG/trace.csv"
unset K3_NOKIO K3_L2_NATIVE
echo "[ab22] start $(date +%T) mem=$(awk '/MemAvailable/{printf "%.1fGB",$2/1048576}' /proc/meminfo)"
echo "[ab22] $LOG clean build + --prefetch-depth 1 + trace"
sync; echo 3 > /proc/sys/vm/drop_caches; sleep 2
/usr/bin/time -f "TIME_ELAPSED=%e" ./bin/k3 /model \
  --trunk /mnt/nvme/trunk_layers_out --embed-dir /mnt/nvme/embed \
  --trunk-gb 6 --cache-gb 40 --prefetch-depth 1 \
  --ids 1008 --gen 8 --out "$LOG/ctrl.json" > "$LOG/ctrl.log" 2>&1
RC=$?
echo "EXIT=$RC"
{
  echo "--- v22_pf1 (clean build, trunk 6GB / cache 40GB, prefetch-depth 1)"
  grep -aE "async expert prefetch|TRUE resident|s/token average|I/O share|experts, whole|phase2|pread\)|bind wall|requests *:|prefetch *:" "$LOG/ctrl.log" | tail -12
  grep -aE "^TIME_ELAPSED" "$LOG/ctrl.log"
  grep -aE "seconds_per_token|trunk_bytes_read|expert_bytes_read|peak_rss_bytes" "$LOG/ctrl.json"
} > "$LOG/summary.txt"
cat "$LOG/summary.txt"
echo "[ab22] trace rows: $(wc -l < "$LOG/trace.csv" 2>/dev/null || echo 0)"
echo "$LOG" > /root/last_trace_dir
echo "[ab22] end $(date +%T)"