#!/bin/bash
# v57 summed the per-invocation rates that dd prints, which was correct in v55 because every
# dd there ran concurrently -- sum of rates then equals the aggregate. Here each stream is a
# CHAIN of 120 sequential dd invocations, so summing inflates by the chain length: the 1-stream
# arm printed 12411 MB/s against a device that does 1600. Dividing by 120 gives ~103, still 16x
# under v55, so the measurement is replaced rather than corrected:
#
#   aggregate = total bytes delivered / wall time of the whole arm
#
# dd's own rate is only used to report short reads. Nothing is summed.
set -u
cd /mnt/f/kimi-k3-in-c
OUT=reports/gateab_ab/v57_expertshape
mkdir -p "$OUT"

L2=/mnt/nvme/experts.l2
SLOT=17547264
NSLOT=$(($(stat -c %s "$L2") / SLOT))
[ "$(stat -c %s "$L2")" -eq $((NSLOT * SLOT)) ] || { echo "partial trailing slot"; exit 1; }
STRIDE=4096
[ $((NSLOT % STRIDE)) -ne 0 ] || { echo "stride not coprime"; exit 1; }
echo "geometry: $NSLOT slots x $SLOT, stride $STRIDE coprime"

# $1 label, $2 streams, $3 reads per stream, $4 sequential(1)/scattered(0)
arm() {
  local label=$1 ns=$2 nrd=$3 seq=$4
  local RAW; RAW=$(mktemp)
  local T0 T1 wall got want
  T0=$(date +%s.%N)
  local k i slot
  for ((k = 0; k < ns; k++)); do
    (
      for ((i = 0; i < nrd; i++)); do
        if [ "$seq" = "1" ]; then slot=$(( i % NSLOT ))
        else slot=$(( (k * 997 + i * STRIDE) % NSLOT )); fi
        dd if="$L2" of=/dev/null bs=$SLOT count=1 skip=$slot iflag=direct,fullblock \
           2>>"$RAW" &
      done
      wait
    ) &
  done
  wait
  T1=$(date +%s.%N)

  # bytes actually delivered, parsed out of dd's own output; short reads are the failure mode
  # that would make a stream look slow rather than broken.
  got=$(awk '/copied,/ {
      for (i = 1; i <= NF; i++) if ($i ~ /^[0-9.]+$/ && $(i+1) == "MB") mb += $i
      n++
    } END { printf "%.0f\t%d", mb, n }' < "$RAW")
  local MB N; MB=$(printf '%s' "$got" | cut -f1); N=$(printf '%s' "$got" | cut -f2)
  want=$(( ns * nrd * SLOT / 1000000 ))

  wall=$(awk -v a="$T0" -v b="$T1" 'BEGIN{printf "%.3f", b-a}')
  local agg
  agg=$(awk -v mb="$MB" -v w="$wall" 'BEGIN{printf "%.0f", mb/w}')

  local per
  per=$(awk -v a="$agg" -v n="$ns" 'BEGIN{printf "%.0f", a/n}')

  if [ "$N" -ne $((ns * nrd)) ]; then
    printf "  %-26s SHORT: %d of %d invocations reported -- not recording\n" \
      "$label" "$N" "$((ns * nrd))"
    rm -f "$RAW"; return 1
  fi
  if [ "$MB" -lt $(( want * 95 / 100 )) ]; then
    printf "  %-26s SHORT BYTES: %s of %s MB -- not recording\n" "$label" "$MB" "$want"
    rm -f "$RAW"; return 1
  fi

  printf "  %-26s %6s MB/s aggregate, %5s per stream  (%.1f GB in %ss, %d invocations)\n" \
    "$label" "$agg" "$per" "$(awk -v m="$MB" 'BEGIN{printf "%.1f", m/1000}')" "$wall" "$N"
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$label" "$ns" "$((ns*nrd))" "$seq" "$agg" "$per" >> "$OUT/raw2.txt"
  rm -f "$RAW"
}

: > "$OUT/raw2.txt"
echo
echo "== smoke: 12 reads, both patterns, must agree with bytes/wall"
arm "SMOKE_scattered_1s" 1 12 0 || exit 1
arm "SMOKE_sequential_1s" 1 12 1 || exit 1
: > "$OUT/raw2.txt"

sleep 150
for _ in $(seq 1 60); do
  l=$(cut -d' ' -f1 /proc/loadavg)
  awk -v a="$l" 'BEGIN{exit !(a<0.5)}' && break
  sleep 15
done
echo "idle: load=$(cut -d' ' -f1-3 /proc/loadavg)  $(date +%T)"

N=120
echo
echo "== scattered 17.5 MB (the engine's expert shape)"
arm "scattered_1s"  1 $N 0
arm "scattered_4s"  4 $N 0
arm "scattered_8s"  8 $N 0
arm "scattered_16s" 16 $N 0
echo
echo "== sequential 17.5 MB, same size and count"
arm "sequential_1s"  1 $N 1
arm "sequential_8s"  8 $N 1
echo
echo "== reference: engine group1 34-46 MB/s per stream at concurrency ~9"
echo "              device 4M blocks  ~1600 MB/s at 4 streams (v55)"
