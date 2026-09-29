#!/bin/bash
# v40: throughput as a function of outstanding reads, at the engine's own concurrency.
#
# v39 removed the cache excuse: with the controller's cache full, the drive still sustains
# 1377 MB/s against the engine's 410. v37 did not test the engine's regime -- its smallest
# arm was 3 slots PER LANE x 16 lanes = 48 concurrent, more than 4x the engine's ~11.
# This sweeps R = 1..16, which brackets it, with read time and pause time kept apart so the
# measurement is the device's and not the pause count.
set -u
cd /mnt/f/kimi-k3-in-c
OUT=reports/gateab_ab/v40_concurrency
mkdir -p "$OUT"
sleep 240
for _ in $(seq 1 80); do
  l=$(cut -d' ' -f1 /proc/loadavg)
  awk -v a="$l" 'BEGIN{exit !(a<0.5)}' && break
  sleep 15
done
{ echo "load before: $(cut -d' ' -f1-3 /proc/loadavg)"
  echo "mem avail : $(awk '/MemAvailable/{printf "%.1f",$2/1048576}' /proc/meminfo)GB"; } > "$OUT/state.txt"
python3 reports/gateab_ab/probe40.py 2>&1 | tee "$OUT/run.txt"
echo "load after: $(cut -d' ' -f1-3 /proc/loadavg)" >> "$OUT/state.txt"
