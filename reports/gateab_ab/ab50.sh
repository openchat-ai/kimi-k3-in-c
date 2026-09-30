#!/bin/bash
# v50: is the 5.3x gap partly "the engine was measured with its prefetcher switched off"?
#
# Every engine measurement today ran at prefetch_depth = 0. k3_run.c:734 only calls
# k3_cache_prefetch_ahead when depth > 0, and cache_getmany_inner takes its `locked` flag
# from c->pref_started, which only that call sets. So with depth 0 the prefetch thread is
# never created, c->mu is never held in phase 1, and the "two threads overlap on the drive"
# the comment describes does not exist. v41's phase 1 = 0.02 s per token was measured on
# that unlocked path, and so were v47's, v48's and v49's engine arms.
#
# The engine's own normal configuration includes the prefetcher, and v22 shows it really
# runs when enabled: "prefetch: issued 387 LATE 0 survival 48.9%". But v22 ran at 6 GB / 40 GB,
# a configuration shown today to drift 23-35% on its own, so it never isolated the variable.
# Prefetch has never been measured on the 32 GB / 15 GB configuration that every other
# number today refers to.
#
# Design: paired A/B, same config, same session, alternating so both arms share whatever
# thermal state the drive is in. Arm A is depth 0, which is the engine baseline the whole day
# rests on; arm B is depth 1. Three pairs. Both arms are the engine, so this does not depend
# on any probe.
set -u
cd /mnt/f/kimi-k3-in-c
OUT=reports/gateab_ab/v50_prefetch
mkdir -p "$OUT"

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

run_one() {   # $1 = tag, $2 = prefetch depth
  local tag=$1 depth=$2
  local LOG="$OUT/$tag-$(date +%Y%m%d_%H%M%S)"
  mkdir -p "$LOG"
  unset K3_TRACE K3_NOKIO K3_L2_NATIVE K3_IO_NW0
  local extra=""
  [ "$depth" -gt 0 ] && extra="--prefetch-depth $depth"
  ./bin/k3 /model \
    --trunk /mnt/nvme/trunk_layers_out --embed-dir /mnt/nvme/embed \
    --trunk-gb 32 --cache-gb 15 $extra \
    --ids 1008 --gen 3 --out "$LOG/ctrl.json" > "$LOG/ctrl.log" 2>&1
  echo "  [$tag depth=$depth]  $(grep -a 's/token average' "$LOG/ctrl.log")"
  grep -aE "async expert prefetch|prefetch *:|TRUE resident|hit I/O|read from disk|peak" \
    "$LOG/ctrl.log" | sed 's/^/      /'
}

for pair in 1 2 3; do
  echo "[v50] pair $pair A (depth 0, baseline)  $(date +%T)"
  run_one "pf0_r$pair" 0
  sleep 20
  echo "[v50] pair $pair B (depth 1)           $(date +%T)"
  run_one "pf1_r$pair" 1
  sleep 20
done

echo "end   : $(date +%T)" >> "$OUT/state.txt"
cat "$OUT/state.txt"
