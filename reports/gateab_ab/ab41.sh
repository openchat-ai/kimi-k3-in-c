#!/bin/bash
# v41: how much of the expert phase is the serial reserve loop, and how much is the device.
#
# v40 measured the drive at 2723 MB/s with the engine's own ~11 outstanding reads, 6.6x the
# 410 MB/s the engine achieves, and v38 found the engine requesting 529 GB while the drive
# moved 265 GB. Half the reads never became physical I/O. The untested suspect is
# cache_getmany_inner's phase 1: the serial reserve loop, pick_victim, and the insertion
# sort, which holds c->mu whenever the prefetcher is running. K3_TRACE has covered phase 2
# and compute since e3268f8 and never phase 1, so its share of the 59.39 s expert union was
# unknown. k3_cache.c now emits a K3_PHASE_WIDEN row per call, including the nw == 0 early
# return that covers every layer with nothing to load.
#
# Same config as v32, so the phase columns are directly comparable: trunk 32 GB / cache
# 15 GB, 16 workers, kio on, no prefetch, --ids 1008 --gen 8, operator idle.
set -u
cd /mnt/f/kimi-k3-in-c
OUT=reports/gateab_ab/v41_phase1
mkdir -p "$OUT"

sleep 240
for _ in $(seq 1 80); do
  l=$(cut -d' ' -f1 /proc/loadavg)
  awk -v a="$l" 'BEGIN{exit !(a<0.5)}' && break
  sleep 15
done
{ echo "load before: $(cut -d' ' -f1-3 /proc/loadavg)"
  echo "mem avail : $(awk '/MemAvailable/{printf "%.1f",$2/1048576}' /proc/meminfo)GB"; } > "$OUT/state.txt"

for rep in 1 2; do
  LOG="$OUT/rep$rep-$(date +%Y%m%d_%H%M%S)"
  mkdir -p "$LOG"
  export K3_TRACE="$LOG/trace.csv"
  unset K3_NOKIO K3_L2_NATIVE K3_IO_NW0
  echo "[v41] rep$rep start $(date +%T)  $(cut -d' ' -f1-3 /proc/loadavg)"
  ./bin/k3 /model \
    --trunk /mnt/nvme/trunk_layers_out --embed-dir /mnt/nvme/embed \
    --trunk-gb 32 --cache-gb 15 \
    --ids 1008 --gen 8 --out "$LOG/ctrl.json" > "$LOG/ctrl.log" 2>&1
  echo "EXIT=$?  end $(date +%T)" >> "$LOG/state.txt"
  echo "[v41] rep$rep done  $(grep -a 's/token average' "$LOG/ctrl.log")  rows=$(($(wc -l < "$LOG/trace.csv") - 1))"
  sleep 30
done
echo "load after: $(cut -d' ' -f1-3 /proc/loadavg)" >> "$OUT/state.txt"
