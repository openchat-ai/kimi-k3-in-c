#!/bin/bash
# The last untested difference between seqprobe (1418 MB/s at 16-way) and the engine
# (453 MB/s). Both read 17.56 MB slots from experts.l2 with 16 concurrent readers.
#
# What differs is WHICH slots. seqprobe used skip=7000+13k -- sixteen slots 228 MB apart,
# a near-sequential sweep. The engine reads the top-16 of one layer, and those 16 experts
# are spread across that layer's 896 slots (15.7 GB region), so the reads are far apart.
# slot_of[layer*896 + expert] makes LAYERS contiguous, not the 16 experts within a layer.
#
# So: same concurrency, same unit size, same file -- only the offset pattern differs.
#   arm A  16 slots 228 MB apart   (what seqprobe measured)
#   arm B  16 slots 1.5 GB apart    (engine-like spread within one layer)
#   arm C  16 slots 7.5 GB apart    (extreme spread)
#   arm D  16 consecutive slots     (pure sequential, the floor case)
set -u
L2=/mnt/nvme/experts.l2
SLOT=$((17600000))          # 17.56 MB
N=16

run() {   # $1=label  $2=base slot  $3=step slots  $4=lanes
  local t0 t1
  t0=$(date +%s.%N)
  for k in $(seq 0 $((N-1))); do
    dd if=$L2 of=/dev/null bs=$SLOT count=1 skip=$(( $2 + k * $3 )) 2>/dev/null &
  done
  wait
  t1=$(date +%s.%N)
  printf "  %-34s %s MB/s aggregate\n" "$1" \
    "$(echo "$((SLOT * N)) / ($t1 - $t0) / 1048576" | bc -l | cut -c1-6)"
}

echo "== 16-way concurrent, offset pattern varying (unit = 17.56 MB slot) =="
run "A: 16 slots, 228 MB apart"  7000 13 16
run "B: 16 slots, 1.5 GB apart"  1000 85 16
run "C: 16 slots, 7.5 GB apart"  2000 427 16
run "D: 16 consecutive slots"    30000 1 16
echo
echo "== repeat A and C once more, in case of warm-up =="
run "A again"  7000 13 16
run "C again"  2000 427 16
echo
echo "engine measured 453 MB/s (16 workers) / 329 (32 workers); v27 K3_L2_NATIVE 408."
echo "nslot = 256e9/17.56e6 = $((256000000000 / SLOT))  (whole experts.l2 in slots)"