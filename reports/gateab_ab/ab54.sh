#!/bin/bash
# v54: can a larger expert arena make the prefetcher survive, and feed the drive?
#
# v52 found where the 2.77x goes: the kio pool's queue time is 2.7% of request time, both
# lock figures are ~0, and the workers sit inside pread 1988 of 3891 available worker-seconds
# -- so about half the time the pool has no work and the drive is idle. The structure is
# layer-serial: read layer L's experts, compute, read L+1.
#
# v50 showed the prefetcher is the mechanism that could break that, and that it fails at
# 15 GB of arena: survival 21.1%, TRUE resident 0.0%, and it cost throughput (355 against
# 476 MB/s) because the wasted reads compete for the same drive.
#
# v53 tried trunk 32 + arena 32 and both arms refused to start: 69.34 GB planned against
# 57.79 GB available. So the combination does not fit on this box and the design has to move
# budget rather than add it. What fits, keeping the total within about 1 GB of the baseline's
# so the comparison is about the split and not about total memory:
#
#   A  32/15 pf0   baseline, 52.3 GB total, already measured at 71.3 / 74.5 s/token
#   B  24/24 pf1   arena 1.6x with prefetch on
#   C  24/24 pf0   arena alone, isolating RAM from prefetch
#   D  16/32 pf1   arena 2x with prefetch on, trunk down to about 11 resident layers
#
# The cost is explicit: trunk residency falls with trunk-gb (32 GB held 22 of 93 layers, so
# 24 GB holds about 16 and 16 GB about 11), and every layer the trunk no longer holds is
# streamed from the same drive that the expert reads are trying to keep busy. If D is worst,
# trunk residency is the hard constraint and no amount of arena buys it back.
#
# Judged on v52's counter, not on s/token: the target is `device MB/s per stream` rising from
# the 108-118 the baseline reports, with `survival` rising from 21%.
set -u
cd /mnt/f/kimi-k3-in-c
OUT=reports/gateab_ab/v54_arena
mkdir -p "$OUT"

sleep 240
for _ in $(seq 1 80); do
  l=$(cut -d' ' -f1 /proc/loadavg)
  awk -v a="$l" 'BEGIN{exit !(a<0.5)}' && break
  sleep 15
done
{ echo "start : $(date +%T)"; echo "load  : $(cut -d' ' -f1-3 /proc/loadavg)"
  echo "mem   : $(awk '/MemAvailable/{printf "%.1fGB",$2/1048576}' /proc/meminfo)"; } > "$OUT/state.txt"

AVAIL=$(awk '/MemAvailable/{printf "%d",$2/1048576}' /proc/meminfo)
echo "available: ${AVAIL} GB"

run_arm() {   # $1 tag, $2 trunk-gb, $3 cache-gb, $4 prefetch depth
  local tag=$1 tg=$2 cg=$3 pd=$4
  local LOG="$OUT/$tag-$(date +%Y%m%d_%H%M%S)"
  mkdir -p "$LOG"
  unset K3_TRACE K3_NOKIO K3_L2_NATIVE K3_IO_NW0
  local extra=""
  [ "$pd" -gt 0 ] && extra="--prefetch-depth $pd"
  ./bin/k3 /model \
    --trunk /mnt/nvme/trunk_layers_out --embed-dir /mnt/nvme/embed \
    --trunk-gb "$tg" --cache-gb "$cg" $extra \
    --ids 1008 --gen 3 --out "$LOG/ctrl.json" > "$LOG/ctrl.log" 2>&1
  local rc=$?
  # The plan is printed before any weights load, so a refusal shows up long before the run
  # would fail. v53 lost two of its six arms to a 69.34-GB plan against 57.79 GB available,
  # discovered 26 seconds in with nothing to show. preflight54.sh confirmed by running each
  # arm to layer ~50 that all four of these start, so this check is a guard rather than the
  # primary evidence.
  local planned
  planned=$(grep -aE "^  TOTAL" "$LOG/ctrl.log" 2>/dev/null | head -1 | awk '{print $2}')
  if [ -z "$planned" ] && [ $rc -ne 0 ]; then
    echo "  [$tag] rc=$rc, no plan -- check $LOG/ctrl.log"
    return 1
  fi
  echo "  [$tag] plan=${planned:-?}GB avail=${AVAIL}GB  $(grep -a 's/token average' "$LOG/ctrl.log" | sed 's/^ *//')"
  grep -aE "^kio tier|expert cache:|prefetch *:|TRUE resident|PINNED|^  read [0-9]" \
    "$LOG/ctrl.log" | sed 's/^/       /'
  return 0
}

ok=0; fail=0
for pair in 1 2; do
  for spec in "A_32_15_pf0_r$pair 32 15 0" "B_24_24_pf1_r$pair 24 24 1" \
               "C_24_24_pf0_r$pair 24 24 0" "D_16_32_pf1_r$pair 16 32 1"; do
    set -- $spec
    echo "[v54] $1  $(date +%T)"
    if run_arm "$@"; then ok=$((ok+1)); else fail=$((fail+1)); fi
    sleep 25
  done
done

echo "end   : $(date +%T)" >> "$OUT/state.txt"
echo "arms ok: $ok   failed: $fail" | tee -a "$OUT/state.txt"
cat "$OUT/state.txt"
