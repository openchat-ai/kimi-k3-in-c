#!/bin/bash
# v47: measure the device over the engine's window.
#
# The comparison that has been running all morning is between two different windows. The
# engine's ledger integrates 179.74 GB over 409.18 s of continuous work; my probes measured
# 23 GB bursts of about four seconds. A 6.2x gap between a 400-second steady state and a
# 4-second cache-warm burst is not yet a finding about the engine -- it is a finding about
# the comparison. Several of this morning's eliminations were explaining that artefact.
#
# One continuous stream for as long as the engine ran, reported in 20 s segments so the
# trajectory is visible rather than just the average. The question is binary: does the rate
# collapse and stay collapsed, in which case 439 MB/s is a steady state and the gap is much
# smaller than claimed; or does it hold at multi-GB/s throughout, in which case the gap is
# real and it is a steady-state-versus-burst difference.
#
# Host counters run alongside, as in v46, because v46 established that % Idle Time, queue
# depth and latency distinguish "device saturated" from "nobody feeding it" and that
# distinction is what makes the number interpretable.
set -u
cd /mnt/f/kimi-k3-in-c
OUT=reports/gateab_ab/v47_steady
mkdir -p "$OUT"

cc -O2 -std=gnu99 -D_GNU_SOURCE -Iinclude -Iinclude/k3 -pthread \
   reports/gateab_ab/steady47.c build/src/io/k3_io.o -o "$OUT/steady47" 2>&1 | head -12
[ -x "$OUT/steady47" ] || { echo "BUILD FAILED"; exit 1; }
echo "built ok"

sleep 240
for _ in $(seq 1 80); do
  l=$(cut -d' ' -f1 /proc/loadavg)
  awk -v a="$l" 'BEGIN{exit !(a<0.5)}' && break
  sleep 15
done
{
  echo "start : $(date +%T)"
  echo "load  : $(cut -d' ' -f1-3 /proc/loadavg)"
  echo "mem   : $(awk '/MemAvailable/{printf "%.1fGB",$2/1048576}' /proc/meminfo)"
} > "$OUT/state.txt"

powershell.exe -NoProfile -ExecutionPolicy Bypass -File \
  "F:\\kimi-k3-in-c\\reports\\gateab_ab\\hostsampler46.ps1" \
  -Seconds 1200 -Out "F:\\kimi-k3-in-c\\reports\\gateab_ab\\v47_steady\\host.csv" \
  > /dev/null 2>&1 &
SAMPLER=$!
sleep 3

# 420 s: slightly longer than the engine's 409 s, so the tail is comparable.
"$OUT/steady47" 420 2>&1 | tee "$OUT/run.txt"
rc=$?
kill $SAMPLER 2>/dev/null; wait $SAMPLER 2>/dev/null

echo "end   : $(date +%T)" >> "$OUT/state.txt"
echo "exit=$rc" >> "$OUT/state.txt"
cat "$OUT/state.txt"
