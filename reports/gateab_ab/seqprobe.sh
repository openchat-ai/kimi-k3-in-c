#!/bin/bash
# Decides whether the expert path's 453 MB/s is a device property or an artifact of
# concurrency. Single-stream sequential read of experts.l2, one slot at a time (17.56 MB,
# the exact unit the engine reads), then the same span read 4- and 16-way in parallel.
#
# Why this is decisive. §5.2.1 of the paper currently blames "tier sequentiality" and
# says the factor cannot be improved because a layer's experts are already contiguous
# (slot_of[layer*896 + expert] into a flat slot array -- true). But v26 showed the rate
# FALLING from 453 to 329 MB/s when workers went 16 -> 32, and random access cannot slow
# down that way. The repo's own probe_coldc measured expert single-stream at 3264 MB/s
# against trunk 1509 -- i.e. the expert bytes are the FASTER stream. So 453 has to be
# explained by concurrency, not by seek order, and this run measures both ends.
set -u
L2=/mnt/nvme/experts.l2
SLOT=$((17600000))          # ~17.56 MB, one expert slot
F=/mnt/nvme/.seqprobe.$$
echo "== single stream, one slot at a time (5 reps):"
for i in 1 2 3 4 5; do
  t0=$(date +%s.%N)
  dd if=$L2 of=/dev/null bs=$SLOT count=1 skip=$((1000 + i * 37)) 2>/dev/null
  t1=$(date +%s.%N)
  echo "  rep$i: $(echo "$SLOT / ($t1 - $t0) / 1048576" | bc -l | cut -c1-6) MB/s"
done
echo
echo "== single stream, 16 consecutive slots (281 MB, one sequential run):"
t0=$(date +%s.%N)
dd if=$L2 of=/dev/null bs=$SLOT count=16 skip=5000 2>/dev/null
t1=$(date +%s.%N)
echo "  $(echo "$((SLOT * 16)) / ($t1 - $t0) / 1048576" | bc -l | cut -c1-6) MB/s"
echo
echo "== 4-way parallel, 4 separate 17.56 MB slots (aggregate):"
t0=$(date +%s.%N)
for k in 0 1 2 3; do
  dd if=$L2 of=/dev/null bs=$SLOT count=1 skip=$((6000 + k * 11)) 2>/dev/null &
done
wait
t1=$(date +%s.%N)
echo "  $(echo "$((SLOT * 4)) / ($t1 - $t0) / 1048576" | bc -l | cut -c1-6) MB/s aggregate"
echo
echo "== 16-way parallel, 16 separate slots (aggregate):"
t0=$(date +%s.%N)
for k in $(seq 0 15); do
  dd if=$L2 of=/dev/null bs=$SLOT count=1 skip=$((7000 + k * 13)) 2>/dev/null &
done
wait
t1=$(date +%s.%N)
echo "  $(echo "$((SLOT * 16)) / ($t1 - $t0) / 1048576" | bc -l | cut -c1-6) MB/s aggregate"
rm -f $F
echo
echo "compare: engine measured 453 MB/s at 16 workers, 329 MB/s at 32 (v25/v26);"
echo "         probe_coldc (repo, 09-24) measured expert single-stream 3264 MB/s."