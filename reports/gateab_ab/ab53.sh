#!/bin/bash
# v53: does giving the arena room make the prefetcher work, and does that feed the drive?
#
# v52 located the 2.77x. The kio pool's queue time is 2.7% of request time, both lock
# figures are ~0, and the workers are inside pread 1988 of 3891 available worker-seconds --
# so roughly half the time the pool has nothing to do and the drive is idle. The cause is
# structural: each layer reads its experts, computes, then the next layer reads. Arithmetic
# happens with nothing queued.
#
# v50 showed the prefetcher is the mechanism that could fix it, and that it does not work at
# 15 GB: issued 1235, survival 21.1%, TRUE resident 0.0%. The arena is 854 slots and a
# layer's batch is 11-16, so a layer of prefetched experts is evicted before the forward
# thread arrives. Worse, prefetch made it slower, 355 against 476 MB/s, because the wasted
# reads compete for the same drive.
#
# So the test is the one combination nobody has run: a big enough arena that prefetch
# survives, with the prefetcher on. 32 GB of arena is 1822 slots, 12 trunk layers pinned,
# which is what the "server" preset describes. Three arms, paired and interleaved so they
# share whatever the drive is doing:
#
#   A  32 GB trunk / 15 GB arena, prefetch off     -- today's baseline, 476 MB/s
#   B  32 GB trunk / 32 GB arena, prefetch on      -- room for prefetch to survive
#   C  32 GB trunk / 32 GB arena, prefetch off     -- isolates the arena size from prefetch
#
# B against A is the question that matters. C separates "more RAM" from "prefetch", because
# if C alone recovers the rate then the arena was the constraint and prefetch is incidental.
set -u
cd /mnt/f/kimi-k3-in-c
OUT=reports/gateab_ab/v53_arena
mkdir -p "$OUT"

sleep 240
for _ in $(seq 1 80); do
  l=$(cut -d' ' -f1 /proc/loadavg)
  awk -v a="$l" 'BEGIN{exit !(a<0.5)}' && break
  sleep 15
done
{ echo "start : $(date +%T)"; echo "load  : $(cut -d' ' -f1-3 /proc/loadavg)"
  echo "mem   : $(awk '/MemAvailable/{printf "%.1fGB",$2/1048576}' /proc/meminfo)"; } > "$OUT/state.txt"

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
  echo "  [$tag] $(grep -a 's/token average' "$LOG/ctrl.log" | sed 's/^ *//')"
  grep -aE "^kio tier|expert cache:|prefetch *:|TRUE resident|hit I/O|^  read [0-9]" \
    "$LOG/ctrl.log" | sed 's/^/       /'
  sleep 25
}

for pair in 1 2; do
  echo "[v53] pair $pair  A  32/15 pf0  $(date +%T)"; run_arm "A_32_15_pf0_r$pair" 32 15 0
  echo "[v53] pair $pair  B  32/32 pf1  $(date +%T)"; run_arm "B_32_32_pf1_r$pair" 32 32 1
  echo "[v53] pair $pair  C  32/32 pf0  $(date +%T)"; run_arm "C_32_32_pf0_r$pair" 32 32 0
done

echo "end   : $(date +%T)" >> "$OUT/state.txt"
cat "$OUT/state.txt"
