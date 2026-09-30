#!/bin/bash
# 12 concurrent 17.5 MB reads split 6/6 between ~0.57 s and ~0.07 s, and the split followed
# the slot index, not the concurrency. Characterise that before anything else: if the device
# is 8x slower in the first ~100 GB of the pool, then the engine's expert rate depends on
# which experts it happens to route to, and that is a different problem from "not enough
# requests in flight".
#
# One output file per read, so nothing interleaves -- the v57b smoke reported 11 of 12
# invocations purely because twelve dd processes were appending to one file.
#
# Reads run one at a time. Concurrency is the variable under test elsewhere; here the only
# question is how long a single read takes as a function of where it lands.
set -u
L2=/mnt/nvme/experts.l2
SLOT=17547264
NSLOT=$(($(stat -c %s "$L2") / SLOT))
D=/tmp/regionmap
rm -rf "$D"; mkdir -p "$D"
OUT=/mnt/f/kimi-k3-in-c/reports/gateab_ab/v57_expertshape

printf '%s\t%s\t%s\n' slot gib secs rate > "$OUT/region.tsv"

# 24 slots spread evenly, then the first 12 in detail, since the effect looked like a boundary
echo "== 24 slots spread across the whole pool, read one at a time"
for i in $(seq 0 23); do
  slot=$(( i * NSLOT / 24 ))
  gib=$(awk -v s="$slot" 'BEGIN{printf "%.0f", s*17547264/1073741824}')
  t=$( { /usr/bin/time -f %e dd if="$L2" of=/dev/null bs=$SLOT count=1 skip=$slot \
           iflag=direct,fullblock ; } 2>&1 | tail -1 )
  rate=$(awk -v s="$SLOT" -v t="$t" 'BEGIN{printf "%.0f", s/t/1e6}')
  printf "  slot=%-6s (%4s GiB)  %6ss  %5s MB/s\n" "$slot" "$gib" "$t" "$rate"
  printf '%s\t%s\t%s\t%s\n' "$slot" "$gib" "$t" "$rate" >> "$OUT/region.tsv"
done

echo
echo "== first 12 slots, fine grained, to locate the boundary"
for i in $(seq 0 11); do
  slot=$(( i * 512 ))
  gib=$(awk -v s="$slot" 'BEGIN{printf "%.0f", s*17547264/1073741824}')
  t=$( { /usr/bin/time -f %e dd if="$L2" of=/dev/null bs=$SLOT count=1 skip=$slot \
           iflag=direct,fullblock ; } 2>&1 | tail -1 )
  rate=$(awk -v s="$SLOT" -v t="$t" 'BEGIN{printf "%.0f", s/t/1e6}')
  printf "  slot=%-6s (%4s GiB)  %6ss  %5s MB/s\n" "$slot" "$gib" "$t" "$rate"
  printf '%s\t%s\t%s\t%s\n' "$slot" "$gib" "$t" "$rate" >> "$OUT/region.tsv"
done

echo
echo "== summary"
awk -F'\t' 'NR>1 {print $4}' "$OUT/region.tsv" | sort -n | \
  awk '{a[NR]=$1} END{printf "  n=%d  min=%s  median=%s  max=%s MB/s\n", NR, a[1], a[int(NR/2)], a[NR]}'
echo "  fast/slow split:"
awk -F'\t' 'NR>1 {print ($4<100?"slow <100":"fast >=100")}' "$OUT/region.tsv" | sort | uniq -c | sed 's/^/    /'
