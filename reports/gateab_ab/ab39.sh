#!/bin/bash
# v39: measure the drive with its own cache deliberately filled, and let the host watch
# while it happens.
#
# v38 established the fact this exists: the engine asked for 529.1 GB and the physical drive
# moved 265.0 GB, was 77.6% busy on average, and the host saw a mean queue depth of 86.75
# while the engine believed it was offering 16. O_DIRECT bypasses the guest's page cache,
# not the controller's own DRAM and SLC cache -- and neither v36 nor v37 preconditioned it,
# so both measured "whatever the cache happened to hold".
#
# This run overwrites the cache with 40 GB of non-experts.l2 data, then measures with no
# idle gap. 196 GB of free space is available, so the write fits.
#
# Cold path: ~2 min. Preconditioning write: ~1 min. 10 samples: ~10 min.
set -u
cd /mnt/f/kimi-k3-in-c
OUT=reports/gateab_ab/v39_cache
mkdir -p "$OUT"

sleep 240
for _ in $(seq 1 80); do
  l=$(cut -d' ' -f1 /proc/loadavg)
  awk -v a="$l" 'BEGIN{exit !(a<0.5)}' && break
  sleep 15
done
{
  echo "load before: $(cut -d' ' -f1-3 /proc/loadavg)"
  echo "mem avail : $(awk '/MemAvailable/{printf "%.1f",$2/1048576}' /proc/meminfo)GB"
  df -h /mnt/nvme | tail -1
} > "$OUT/state.txt"

python3 reports/gateab_ab/probe39.py 2>&1 | tee "$OUT/run.txt"

echo "load after: $(cut -d' ' -f1-3 /proc/loadavg)" >> "$OUT/state.txt"
cat "$OUT/state.txt"
