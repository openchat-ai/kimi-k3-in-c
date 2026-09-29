#!/bin/bash
# Run the rebuilt device probe. Leaves the machine otherwise idle: no k3 run, no compile.
# The probe reads /mnt/nvme/experts.l2, which is the file a k3 run would read, so nothing
# else may touch the disk while this is in flight.
set -u
cd /mnt/f/kimi-k3-in-c
OUT=reports/gateab_ab/v36_devrate
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
python3 reports/gateab_ab/probe36.py 2>&1 | tee "$OUT/run.txt"
{
  echo
  echo "load after: $(cut -d' ' -f1-3 /proc/loadavg)"
} >> "$OUT/state.txt"
cat "$OUT/state.txt"
