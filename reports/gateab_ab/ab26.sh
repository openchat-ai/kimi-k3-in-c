#!/bin/bash
# v26: is 418 MB/s on the expert path this drive's random-read ceiling, or a queue-depth
# limit we can raise? Clean build, 32 workers (was 16), trace on so the phase-2 rate and the
# exposed expert time both come out of the same run.
#
# Why this matters now. The 8-token trace put the wall at 66.12 s/token with 49.2 s of it
# exposed expert reads moving 22.5 GB/token -- that is 418 MB/s, while trunk's sequential
# reads on the same drive run 890 MB/s. Pure arithmetic is only 16.8 s/token, so arithmetic
# cannot possibly hide a 53.8 s serial read. The 2x gap between sequential and expert reads
# is seek behaviour, and if it is a queue-depth limit rather than the drive's random-read
# capability, more workers is free performance.
#
# The earlier 32-worker run (v15) is not evidence either way: it ran against the
# stale-objectfile binary and predates the trace, so it could not report a phase-2 rate.
#
# What to read afterwards:
#   phase2 i/o rate in the summary   >418 MB/s means queue depth was the limit
#                                     ~418 means this is the drive's random ceiling
#   expert wall per token from the trace   should fall in proportion if the rate rises
set -u
cd /mnt/f/kimi-k3-in-c
LOG=/mnt/f/kimi-k3-in-c/reports/gateab_ab/v26_nw32-$(date +%Y%m%d_%H%M%S)
mkdir -p "$LOG"
export K3_TRACE="$LOG/trace.csv"
export K3_IO_NW0=32
unset K3_NOKIO K3_L2_NATIVE
echo "[ab26] start $(date +%T) mem=$(awk '/MemAvailable/{printf "%.1fGB",$2/1048576}' /proc/meminfo)"
echo "[ab26] $LOG trunk 32GB / cache 15GB, 32 workers (was 16), trace on"
sync; echo 3 > /proc/sys/vm/drop_caches; sleep 2
/usr/bin/time -f "TIME_ELAPSED=%e" ./bin/k3 /model \
  --trunk /mnt/nvme/trunk_layers_out --embed-dir /mnt/nvme/embed \
  --trunk-gb 32 --cache-gb 15 \
  --ids 1008 --gen 8 --out "$LOG/ctrl.json" > "$LOG/ctrl.log" 2>&1
RC=$?
unset K3_IO_NW0
echo "EXIT=$RC"
{
  echo "--- v26_nw32 (clean build, trunk 32GB / cache 15GB, K3_IO_NW0=32, trace on)"
  grep -aE "PINNED|TRUE resident|s/token average|I/O share|experts, whole|phase2|pread\)|bind wall|requests *:" "$LOG/ctrl.log" | tail -12
  grep -aE "^TIME_ELAPSED" "$LOG/ctrl.log"
  grep -aE "seconds_per_token|trunk_bytes_read|expert_bytes_read|peak_rss_bytes" "$LOG/ctrl.json"
} > "$LOG/summary.txt"
cat "$LOG/summary.txt"
echo "[ab26] trace rows: $(wc -l < "$LOG/trace.csv" 2>/dev/null || echo 0)"
echo "$LOG" > /root/last_trace_dir
echo "[ab26] end $(date +%T)"