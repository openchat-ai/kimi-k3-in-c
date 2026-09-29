#!/bin/bash
# Burst-geometry probe. Same device, same unit, same 16 lanes, same 21 GB total; only the
# burst granularity and the pause vary. The arm that reproduces the engine's 410 MB/s
# identifies the regime the engine is actually running in.
set -u
cd /mnt/f/kimi-k3-in-c
OUT=reports/gateab_ab/v37_burst
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
  echo
} > "$OUT/state.txt"
python3 reports/gateab_ab/probe37.py 2>&1 | tee "$OUT/run.txt"
echo "load after: $(cut -d' ' -f1-3 /proc/loadavg)" >> "$OUT/state.txt"
cat "$OUT/state.txt"
