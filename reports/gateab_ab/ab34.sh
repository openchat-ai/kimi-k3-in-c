#!/bin/bash
# v34: trustworthy 6/40 vs 32/15, interleaved, with a settling period.
#
# Three questions, one run.
#
#   1. The loadavg gate was a hole. wait_idle() checked /proc/loadavg field 1 only. v33
#      showed why that is not enough: rep1 started at 1min 0.99 / 5min 0.39 / 15min 0.14
#      and read 80.33 s/token; rep2 started at 1min 0.92 / 5min 4.85 / 15min 4.05 and
#      read 101.09 -- byte-for-byte identical work (137.01 GB, 53.04% retained, 5530
#      evictions, 43.00% TRUE hit, both arms' numbers identical to the digit) on a wall
#      26% longer. So the gate admitted a run whose device throughput was a quarter down.
#      v30 cannot be checked, because it never recorded 5min or 15min at all.
#
#   2. Therefore the day's headline "80.93 -> 73.96 = -8.6%" is unverified: it compares a
#      v18 single unregulated run against a v30 median whose cleanliness was never
#      recorded. Both arms are re-measured here under one protocol.
#
#   3. Is 32/15 actually more stable than 6/40, or was v30's 3.4% luck? v33 spread 26%,
#      v30 spread 3.4%. That gap is either a real property of the memory split or an
#      artifact of how idle each run happened to start. Only an interleaved run separates
#      the two, because interleaving makes both arms inherit the same settling history.
#
# Design:
#   - arms interleaved A B A B A B, so neither arm systematically runs on a colder or
#     warmer machine than the other
#   - fixed 240 s settle after every run, then wait for 1min < 0.3 (up to 20 min)
#   - 1min, 5min AND 15min recorded before and after every run, which is the field v30
#     omitted and without which none of this is checkable later
#   - drop_caches before every run
#   - no K3_TRACE: v30's 73.96 was traced off, and the tracer costs ~2.8%
#   - per-token times stay in ctrl.log, so a swing can be attributed to the start of a run
#     or spread across all of it
set -u
cd /mnt/f/kimi-k3-in-c
OUT=/mnt/f/kimi-k3-in-c/reports/gateab_ab/v34_ab
mkdir -p "$OUT"

snapshot() {
  echo "1min/5min/15min = $(cut -d' ' -f1-3 /proc/loadavg)"
  echo "mem_avail = $(awk '/MemAvailable/{printf "%.1f",$2/1048576}' /proc/meminfo)GB"
  echo "dirty    = $(awk '/^Dirty:/{printf "%.1f",$2/1048576}' /proc/meminfo)GB"
  echo "anon      = $(awk '/^AnonPages:/{printf "%.1f",$2/1048576}' /proc/meminfo)GB"
}

settle() {
  # Fixed pause first, then a real gate. The pause is what v33 lacked: rep2 started while
  # the previous run's 5min/15min tail was still 4.85/4.05.
  sleep 240
  for i in $(seq 1 80); do
    l=$(cut -d' ' -f1 /proc/loadavg)
    if awk -v a="$l" 'BEGIN{exit !(a<0.3)}'; then return 0; fi
    sleep 15
  done
  echo "WARN: 1min never fell below 0.3, proceeding"
}

run_arm() {   # $1 = arm tag, $2 = trunk-gb, $3 = cache-gb
  local tag=$1 tg=$2 cg=$3
  settle
  local LOG="$OUT/$tag-$(date +%Y%m%d_%H%M%S)"
  mkdir -p "$LOG"
  { echo "=== $tag (trunk ${tg}GB / cache ${cg}GB)"; echo "-- before"; snapshot; } > "$LOG/state.txt"
  sync; echo 3 > /proc/sys/vm/drop_caches; sleep 2
  { echo "-- after drop_caches"; snapshot; } >> "$LOG/state.txt"

  unset K3_TRACE K3_NOKIO K3_L2_NATIVE K3_IO_NW0
  echo "[v34] $tag start $(date +%T)  $(cut -d' ' -f1-3 /proc/loadavg)"
  ./bin/k3 /model \
    --trunk /mnt/nvme/trunk_layers_out --embed-dir /mnt/nvme/embed \
    --trunk-gb "$tg" --cache-gb "$cg" \
    --ids 1008 --gen 8 --out "$LOG/ctrl.json" > "$LOG/ctrl.log" 2>&1
  echo "EXIT=$?  end $(date +%T)" >> "$LOG/state.txt"
  { echo "-- after"; snapshot; } >> "$LOG/state.txt"
  echo "[v34] $tag done  $(grep -a 's/token average' "$LOG/ctrl.log")"
}

for rep in 1 2 3; do
  run_arm "t32c15_r$rep" 32 15
  run_arm "t6c40_r$rep"   6 40
done

echo "[v34] all 6 runs complete $(date +%T)"
