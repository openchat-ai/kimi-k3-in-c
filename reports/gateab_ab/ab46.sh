#!/bin/bash
# v46: catch the collapse in the act.
#
# v45's fixed-base series gave 6244 / 6945 / 7057 / 7075 / 1580 / 7047 -- five samples inside
# 1.13x and one at a quarter of that. That is bimodal, not a drift, and v44's "3.4x
# round-to-round" was most likely one collapse landing in a five-sample window rather than a
# trend. Its varied-base series fell monotonically with base (6259 down to 1863), which is a
# real region effect, but the fixed-base series proved the same region can run at 7047.
#
# Two changes over v45. Each measurement is now split into 6 batches of 120 rounds, so a
# collapse that lasts a second shows up as one slow batch and a collapse that lasts the run
# shows up as six slow ones -- different faults, and they need different explanations. And
# every batch line carries a wall-clock stamp, because the host samples PhysicalDisk once a
# second from the other side of the hypervisor and the only way to learn what the drive was
# doing during the bad sample is to line the two up.
#
# 12 measurements x 6 batches x 23 GB = 1.66 TB of reads, roughly 4 minutes at the rates
# seen so far.
set -u
cd /mnt/f/kimi-k3-in-c
OUT=reports/gateab_ab/v46_drift
mkdir -p "$OUT"

cc -O2 -std=gnu99 -D_GNU_SOURCE -Iinclude -Iinclude/k3 -pthread \
   reports/gateab_ab/drift45.c build/src/io/k3_io.o -o "$OUT/drift45" 2>&1 | head -10
[ -x "$OUT/drift45" ] || { echo "BUILD FAILED"; exit 1; }
echo "built ok"

sleep 240
for _ in $(seq 1 80); do
  l=$(cut -d' ' -f1 /proc/loadavg)
  awk -v a="$l" 'BEGIN{exit !(a<0.5)}' && break
  sleep 15
done
{
  echo "load before: $(cut -d' ' -f1-3 /proc/loadavg)"
  echo "mem avail : $(awk '/MemAvailable/{printf "%.1f",$2/1048576}' /proc/meminfo)GB"
  echo "start     : $(date +%T)"
} > "$OUT/state.txt"

# Host sampler runs alongside, detached, and is killed when the probe finishes.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File \
  "F:\\kimi-k3-in-c\\reports\\gateab_ab\\hostsampler46.ps1" \
  -Seconds 900 -Out "F:\\kimi-k3-in-c\\reports\\gateab_ab\\v46_drift\\host.csv" \
  > /dev/null 2>&1 &
SAMPLER=$!
sleep 3
echo "host sampler pid $SAMPLER"

"$OUT/drift45" 2>&1 | tee "$OUT/run.txt"
rc=$?
kill $SAMPLER 2>/dev/null
wait $SAMPLER 2>/dev/null

echo "exit=$rc" >> "$OUT/state.txt"
echo "end     : $(date +%T)" >> "$OUT/state.txt"
echo "host.csv lines: $(wc -l < "$OUT/host.csv" 2>/dev/null || echo 0)"
cat "$OUT/state.txt"
