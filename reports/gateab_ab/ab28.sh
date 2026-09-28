#!/bin/bash
# v28: the host is 8 physical cores (16 SMT threads) while WSL hands the guest 16 vCPUs.
# The engine currently runs 16 OMP threads PLUS 16 kio workers on that, and the
# benchmark showed dispersion rising with lane count (iqr/median 0.42 -> 0.59 -> 1.32/1.74
# at 1/4/16 lanes), which is the shape of SMT contention. If contention is the cost,
# dropping to the physical core count should be faster, not slower.
#
# v26 already showed 32 workers is worse (75.26). This asks the other direction:
# 8 workers (physical cores) against the 16-worker control (v25 = 68.54).
#
# Note the OMP side is not touched: the expert loop is `omp parallel for num_threads(16)`
# in k3_cache.c, so this only moves the kio pool. If 8 wins, the next probe is the OMP
# side; if 8 does not win, the 32-thread oversubscription theory is wrong and the
# 453 MB/s stays unexplained.
set -u
cd /mnt/f/kimi-k3-in-c
LOG=/mnt/f/kimi-k3-in-c/reports/gateab_ab/v28_nw8-$(date +%Y%m%d_%H%M%S)
mkdir -p "$LOG"
export K3_TRACE="$LOG/trace.csv"
export K3_IO_NW0=8
unset K3_NOKIO K3_L2_NATIVE
echo "[ab28] start $(date +%T) lscpu: $(lscpu | awk -F: '/^CPU\(s\)/{gsub(/ /,"",$2);print $2}') vCPU"
echo "== host physical cores:"; lscpu | grep -E "Thread\(s\) per core|Core\(s\) per socket|Socket\(s\)"
echo "[ab28] $LOG trunk 32GB / cache 15GB, K3_IO_NW0=8 (was 16)"
sync; echo 3 > /proc/sys/vm/drop_caches; sleep 2
/usr/bin/time -f "TIME_ELAPSED=%e" ./bin/k3 /model \
  --trunk /mnt/nvme/trunk_layers_out --embed-dir /mnt/nvme/embed \
  --trunk-gb 32 --cache-gb 15 \
  --ids 1008 --gen 8 --out "$LOG/ctrl.json" > "$LOG/ctrl.log" 2>&1
RC=$?
unset K3_IO_NW0
echo "EXIT=$RC"
{
  echo "--- v28_nw8 (trunk 32GB / cache 15GB, K3_IO_NW0=8, trace on)"
  grep -aE "PINNED|TRUE resident|s/token average|I/O share|experts, whole|phase2|pread\)|bind wall" "$LOG/ctrl.log" | tail -12
  grep -aE "^TIME_ELAPSED" "$LOG/ctrl.log"
  grep -aE "seconds_per_token|trunk_bytes_read|expert_bytes_read" "$LOG/ctrl.json"
} > "$LOG/summary.txt"
cat "$LOG/summary.txt"
echo "[ab28] trace rows: $(wc -l < "$LOG/trace.csv" 2>/dev/null || echo 0)"
echo "$LOG" > /root/last_trace_dir
echo "[ab28] end $(date +%T)"