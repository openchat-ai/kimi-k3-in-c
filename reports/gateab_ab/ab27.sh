#!/bin/bash
# v27: does the expert path's two-level scheduling cost the 68%?
#
# seqprobe.sh measured what the same drive delivers on the engine's own 17.56 MB read
# unit: 673 MB/s single-stream, 714 at 4-way, 1418 at 16-way. The engine takes 453.
# Going 16 -> 32 workers LOWERS it to 329, so the loss is not seek order and not queue
# depth -- it is somewhere in how the requests are issued.
#
# The suspect: cache_getmany_inner runs an OMP loop (16 threads) in which each thread
# calls k3_l2_load_direct, which -- when l2->kio is set -- submits into the kio queue and
# blocks in k3_io_wait (k3_cache.c:289 -> k3_l2cache.c:261). So every expert read crosses
# OMP -> kio queue -> kio worker -> OMP. K3_L2_NATIVE=1 removes the middle hop: the same
# read becomes a direct pread on the OMP thread that issued it.
#
# Control: v25 (trunk 32 / cache 15, 16 workers, clean build) = 68.54 s/token, expert phase
# 453 MB/s. Same config, same binary, only this env var differs.
#
# Read afterwards:
#   expert rate in the trace / phase2 counter  >700 MB/s means the middle hop was the loss
#   s/token                              if it lands near 40 the 34 s gate is in reach
set -u
cd /mnt/f/kimi-k3-in-c
LOG=/mnt/f/kimi-k3-in-c/reports/gateab_ab/v27_l2native-$(date +%Y%m%d_%H%M%S)
mkdir -p "$LOG"
export K3_TRACE="$LOG/trace.csv"
export K3_L2_NATIVE=1
unset K3_NOKIO K3_IO_NW0
echo "[ab27] start $(date +%T) mem=$(awk '/MemAvailable/{printf "%.1fGB",$2/1048576}' /proc/meminfo)"
echo "[ab27] $LOG trunk 32GB / cache 15GB, K3_L2_NATIVE=1 (L2 hit reads bypass the kio queue)"
sync; echo 3 > /proc/sys/vm/drop_caches; sleep 2
/usr/bin/time -f "TIME_ELAPSED=%e" ./bin/k3 /model \
  --trunk /mnt/nvme/trunk_layers_out --embed-dir /mnt/nvme/embed \
  --trunk-gb 32 --cache-gb 15 \
  --ids 1008 --gen 8 --out "$LOG/ctrl.json" > "$LOG/ctrl.log" 2>&1
RC=$?
unset K3_L2_NATIVE
echo "EXIT=$RC"
{
  echo "--- v27_l2native (trunk 32GB / cache 15GB, K3_L2_NATIVE=1, trace on)"
  grep -aE "PINNED|TRUE resident|s/token average|I/O share|experts, whole|phase2|pread\)|bind wall|requests *:" "$LOG/ctrl.log" | tail -12
  grep -aE "^TIME_ELAPSED" "$LOG/ctrl.log"
  grep -aE "seconds_per_token|trunk_bytes_read|expert_bytes_read|peak_rss_bytes" "$LOG/ctrl.json"
} > "$LOG/summary.txt"
cat "$LOG/summary.txt"
echo "[ab27] trace rows: $(wc -l < "$LOG/trace.csv" 2>/dev/null || echo 0)"
echo "$LOG" > /root/last_trace_dir
echo "[ab27] end $(date +%T)"