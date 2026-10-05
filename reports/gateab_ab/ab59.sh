#!/bin/bash
# Which of the 10-01 commits cost 12 s/token? The engine went from 65.21 s/token on the 09-30
# build (008449c) to 76.72-87.56 on e4e206a, and e4e206a's own spread_parse predicted a gain
# from a baseline it was still reading as 65.21. So the number every conclusion since rests on
# stopped matching the binary.
#
# Four distinct src/include states exist between 008449c and e4e206a:
#     008449c  my counter fix, no notes commit after it yet
#     40a9e11  overlap model + k3_cache.c touch
#     ca0e9b9  async burst: hide MoE down-projection under the expert read (4 files)
#     3ea020c  hide the shared expert behind the async burst (k3_ops.c)
#     e4e206a  notes only, src identical to 3ea020c
#
# One run per point. The effect being looked for is 18% and the engine's own spread on a fixed
# config is 11.6%, so a single run separates these; what it cannot do is resolve a small
# regression, so the winner gets a paired confirmation afterwards rather than being called
# guilty on one number.
#
# Only src/ and include/ are moved between points. The working tree's only local edit is
# reports/gateab_ab/overlap_sim.py, which none of these touch, so it survives all four.
set -u
cd /mnt/f/kimi-k3-in-c
OUT=reports/gateab_ab/v59_bisect
mkdir -p "$OUT"
START=$(git rev-parse --short HEAD)
echo "start HEAD=$START  $(date +%T)"
echo "$START" > "$OUT/orig_head.txt"

sleep 120
for _ in $(seq 1 60); do
  l=$(cut -d' ' -f1 /proc/loadavg)
  awk -v a="$l" 'BEGIN{exit !(a<0.5)}' && break
  sleep 15
done
echo "idle: load=$(cut -d' ' -f1-3 /proc/loadavg)  $(date +%T)"

for C in 008449c 40a9e11 ca0e9b9 3ea020c; do
  echo
  echo "===== $C  $(date +%T)"
  git checkout "$C" -- src include 2>&1 | sed 's/^/  checkout: /'
  make clean >/dev/null 2>&1
  if ! make -j8 > "$OUT/build-$C.log" 2>&1; then
    echo "  BUILD FAILED -- see $OUT/build-$C.log"; continue
  fi
  ymm=$(objdump -d bin/k3 | grep -c ymm)
  echo "  built, ymm=$ymm  $([ "$ymm" -gt 1000 ] && echo AVX2-ok || echo DEGRADED-323)"
  [ "$ymm" -lt 1000 ] && { echo "  degraded AVX2, results not comparable"; continue; }

  LOG="$OUT/$C"
  mkdir -p "$LOG"
  unset K3_TRACE K3_NOKIO K3_L2_NATIVE K3_IO_NW0 K3_SPREAD_DBG
  ./bin/k3 /model \
    --trunk /mnt/nvme/trunk_layers_out --embed-dir /mnt/nvme/embed \
    --trunk-gb 32 --cache-gb 15 \
    --ids 1008 --gen 3 --out "$LOG/ctrl.json" > "$LOG/ctrl.log" 2>&1
  spt=$(grep -aoE "[0-9.]+ s/token average" "$LOG/ctrl.log" | head -1)
  agg=$(grep -aoE "aggregate [0-9]+ MB/s" "$LOG/ctrl.log" | head -1)
  echo "  $spt   [$agg]"
  grep -aE "^kio tier0|^      group" "$LOG/ctrl.log" | sed 's/^/      /'
  printf "%s\t%s\t%s\n" "$C" "$spt" "$agg" >> "$OUT/summary.tsv"
  sleep 25
done

# Put the tree back exactly as it was, or the next build picks up someone else's src.
git checkout "$START" -- src include
echo
echo "restored src/include to $START"
make clean >/dev/null 2>&1 && make -j8 >/dev/null 2>&1 && echo "rebuilt at $START"
echo
echo "== summary"
printf "  %-10s %-28s %s\n" commit s/token aggregate
cat "$OUT/summary.tsv" 2>/dev/null | sed 's/^/  /'
echo "end $(date +%T)"