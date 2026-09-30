#!/bin/bash
# Does the per-group split hold up? The 20x gap between group0 (trunk, 1043 MB/s per stream)
# and group1 (experts, 52 MB/s) decides what cross-layer pipelining would even be for, so it
# has to be stable before acting on it.
#
# One run is not evidence -- the engine's own repetition is 66.61 to 75.53 on an identical
# configuration, a 13% spread. Three paired runs, and the check is that the SIGN and rough
# SIZE of the gap hold, not that the numbers match to a decimal.
#
# Also watching: the two rates should not trade off. If group0 and group1 move in opposite
# directions between runs, they are competing and the split is a scheduling artifact rather
# than a property of the workload.
set -u
cd /mnt/f/kimi-k3-in-c
OUT=reports/gateab_ab/v56_groupcheck
mkdir -p "$OUT"

sleep 120
for _ in $(seq 1 60); do
  l=$(cut -d' ' -f1 /proc/loadavg)
  awk -v a="$l" 'BEGIN{exit !(a<0.5)}' && break
  sleep 15
done
echo "idle: load=$(cut -d' ' -f1-3 /proc/loadavg)  $(date +%T)"

for r in 1 2 3; do
  LOG="$OUT/r$r-$(date +%Y%m%d_%H%M%S)"
  mkdir -p "$LOG"
  ./bin/k3 /model \
    --trunk /mnt/nvme/trunk_layers_out --embed-dir /mnt/nvme/embed \
    --trunk-gb 32 --cache-gb 15 \
    --ids 1008 --gen 3 --out "$LOG/ctrl.json" > "$LOG/ctrl.log" 2>&1
  echo "[r$r] $(grep -a 's/token average' "$LOG/ctrl.log" | sed 's/^ *//')"
  grep -aE "^kio tier0|^      group" "$LOG/ctrl.log" | sed 's/^/      /'
  sleep 25
done
echo "done $(date +%T)"
