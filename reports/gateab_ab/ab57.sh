#!/bin/bash
# Is the expert stream slow because the device is slow at that shape, or because the engine
# never has enough of those reads in flight?
#
# v56 measured, three times, identically:
#     group0 trunk    235 reqs  140.16 GB   781-1003 MB/s per stream   queue 0.1s
#     group1 experts 4360 reqs   76.51 GB    34-46  MB/s per stream   queue 57-70s
#     16 workers     concurrency 8.9-10.0x, workers asleep 40-49% of the time
#
# So the workers are idle, and the expert requests that do arrive are slow. Two possible
# causes, and they need opposite responses:
#
#   (a) The device is slow at "one 17.5 MB read at a random offset in a 256 GB file". Then
#       there is nothing for cross-layer pipelining to recover and the work should stop here.
#   (b) The device is fine at that shape and the engine simply has too few outstanding. Then
#       pipelining is the right fix and it should be worth roughly the 40-49% sleep.
#
# v55 does not answer this. It measured 4M blocks, and 1740 MB/s scattered, but the engine
# never reads 4M blocks -- it reads 17.5 MB slots, 4360 of them, spread across the pool. So
# the shape that matters most has never been measured on this device.
#
# Controls, because "random" and "large request" are confounded otherwise:
#   sequential 17.5 MB, same count, same size -- isolates the access pattern
#   1, 4, 8 streams -- the engine runs at about 9, so 8 is the comparison that matters
set -u
cd /mnt/f/kimi-k3-in-c
OUT=reports/gateab_ab/v57_expertshape
mkdir -p "$OUT"

L2=/mnt/nvme/experts.l2
SLOT=17547264                      # slot_bytes, from the engine's own geometry line
NSLOT_ENGINE=14589                 # nslot, likewise
if [ ! -r "$L2" ]; then echo "cannot read $L2 -- refusing to guess geometry"; exit 1; fi
FSIZE=$(stat -c %s "$L2")
NSLOT_FILE=$((FSIZE / SLOT))
if [ $((FSIZE % SLOT)) -ne 0 ]; then
  echo "file size $FSIZE is not a whole number of $SLOT-byte slots; last slot is partial"
  echo "  refusing: a partial read would show up as a short read and be counted as a slow stream"
  exit 1
fi
if [ "$NSLOT_FILE" -ne "$NSLOT_ENGINE" ]; then
  echo "GEOMETRY MISMATCH: file gives $NSLOT_FILE slots, engine printed $NSLOT_ENGINE"
  echo "  (file $(numfmt --to=iec $FSIZE) / slot $SLOT)"
  exit 1
fi
echo "geometry ok: $NSLOT_FILE slots x $SLOT = $(numfmt --to=iec $((FSIZE)))"

# 4096 is a power of two and 14589 is odd, so the stride is coprime with the slot count and
# the walk visits every slot before repeating. A non-coprime stride would sample a fraction
# of the pool and quietly flatter the result.
STRIDE=4096
if [ $((NSLOT_FILE % STRIDE)) -eq 0 ]; then echo "stride not coprime with nslot"; exit 1; fi
echo "stride $STRIDE, coprime with $NSLOT_FILE: $([ $((NSLOT_FILE % STRIDE)) -ne 0 ] && echo yes)"

to_bytes() { case "$1" in
    *K) echo $(( ${1%K} * 1024 )) ;; *M) echo $(( ${1%M} * 1048576 )) ;;
    *G) echo $(( ${1%G} * 1073741824 )) ;; *) echo "$1" ;; esac; }

sum_rates() {
  awk '
    /copied,/ {
      for (i = 1; i <= NF; i++) {
        if ($i ~ /^[0-9.]+$/ && $(i+1) == "GB/s") rate += $i * 1024
        else if ($i ~ /^[0-9.]+$/ && $(i+1) == "MB/s") rate += $i
        else if ($i ~ /^[0-9.]+$/ && $(i+1) == "kB/s") rate += $i / 1024
      }
      s++
    }
    END { if (s > 0) printf "%.0f\t%d", rate, s; else print "?\t0" }'
}

# $1 label, $2 streams, $3 reads each, $4 sequential(1) or scattered(0)
arm() {
  local label=$1 ns=$2 nrd=$3 seq=$4
  local RAW; RAW=$(mktemp)
  local i k slot off
  for ((k = 0; k < ns; k++)); do
    (
      for ((i = 0; i < nrd; i++)); do
        if [ "$seq" = "1" ]; then
          slot=$(( i ))
        else
          # a different starting offset per stream, same coprime walk
          slot=$(( (k * nrd + i * STRIDE) % NSLOT_FILE ))
        fi
        off=$(( slot * SLOT ))
        dd if="$L2" of=/dev/null bs=$SLOT count=1 skip=$slot iflag=direct,fullblock \
           2>>"$RAW" &
      done
      wait
    ) &
  done
  wait
  local parsed; parsed=$(sum_rates < "$RAW")
  local got; got=$(printf '%s' "$parsed" | cut -f2)
  if [ "$got" -eq 0 ]; then
    printf "  %-30s NO PARSE -- aborting\n" "$label"
    head -3 "$RAW" | sed 's/^/      /'
    rm -f "$RAW"; return 1
  fi
  local rate; rate=$(printf '%s' "$parsed" | cut -f1)
  printf "  %-30s %6s MB/s  (%d reads across %d streams)\n" \
    "$label" "$rate" "$((ns * nrd))" "$ns"
  printf '%s\t%s\t%s\t%s\t%s\n' "$label" "$ns" "$((ns*nrd))" "$seq" "$rate" >> "$OUT/raw.txt"
  rm -f "$RAW"
}

# --- smoke: geometry, stride, the 17.5 MB block size, the parse. 20 reads is enough to catch
# a unit change or a short read, and cheap enough to run before the arms.
echo
echo "== smoke"
: > "$OUT/raw.txt"
arm "SMOKE_1s_20r" 1 20 0 || exit 1
grep -q SMOKE "$OUT/raw.txt" || { echo "smoke did not record"; exit 1; }
: > "$OUT/raw.txt"

sleep 150
for _ in $(seq 1 60); do
  l=$(cut -d' ' -f1 /proc/loadavg)
  awk -v a="$l" 'BEGIN{exit !(a<0.5)}' && break
  sleep 15
done
echo "idle: load=$(cut -d' ' -f1-3 /proc/loadavg)  $(date +%T)"

N=120
echo
echo "== scattered 17.5 MB, the shape the engine actually uses"
arm "scattered 1 stream  x120" 1 $N 0
arm "scattered_4s_x120" 4 $N 0
arm "scattered_8s_x120" 8 $N 0
arm "scattered_16s_x120" 16 $N 0

echo
echo "== sequential 17.5 MB, same size and count (isolates the pattern)"
arm "sequential 1 stream x120" 1 $N 1
arm "sequential_8s_x120" 8 $N 1

echo
echo "== for comparison"
echo "  engine group1 (experts)      34-46 MB/s per stream, concurrency ~9"
echo "  engine group0 (trunk)       781-1003 MB/s per stream"
echo "  device ceiling, 4M blocks      ~1600 MB/s at 4 streams (v55)"
