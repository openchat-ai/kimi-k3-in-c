#!/bin/bash
# v60's first attempt returned "0 MB/s" next to "13179 reads". Two independent bugs, both mine.
#
#   1. The byte parser looked for a bare number followed by a bare "MB". dd actually prints
#      "17547264 bytes (18 MB, 17 MiB) copied, 0.07 s, 247 MB/s" -- the number is glued to a
#      leading parenthesis and the unit carries a trailing comma. So $(i+1) == "MB" never
#      matched. The v55 parser matched only "MB/s", which has no trailing punctuation, and
#      worked; adding a second unit silently broke it.
#
#   2. The loop tested the clock with $(date +%s) on every iteration, forking per read per
#      stream. Load average went to 21.7, arms took 166 s when 45 s was asked for, and only
#      5479 of 10262 reads produced any output at all -- half the reads died to the fork storm
#      and were counted as neither bytes nor failures.
#
# Both are fixed. The clock is gone: each arm is given a fixed per-stream read count derived
# from a byte target, so the two shapes move the SAME number of bytes and the comparison is
# about the request shape alone. The parser strips punctuation from both ends of each field.
set -u
cd /mnt/f/kimi-k3-in-c
OUT=reports/gateab_ab/v60_shape
mkdir -p "$OUT"
SPOOL="$OUT/spool"; mkdir -p "$SPOOL"

L2=/mnt/nvme/experts.l2
SLOT=17547264
FSIZE=$(stat -c %s "$L2")
NSLOT=$((FSIZE / SLOT))
[ $((FSIZE % SLOT)) -eq 0 ] || { echo "partial trailing slot"; exit 1; }
STRIDE=4096
[ $((NSLOT % STRIDE)) -ne 0 ] || { echo "stride not coprime"; exit 1; }
echo "geometry: $NSLOT slots x $SLOT, stride $STRIDE coprime"

NS=8
BYTES_PER_STREAM=$(( 1500000000 ))       # 1.5 GB per stream, so 12 GB per arm either shape

# strip leading/trailing punctuation, then match number+unit
sum_reads() {
  cat "$1"/* 2>/dev/null | awk '
    /copied,/ {
      for (i = 1; i <= NF; i++) {
        v = $i; u = $(i+1)
        gsub(/^[^0-9.]+/, "", v); gsub(/[^0-9.]$/, "", u)
        if (v != "" && v ~ /^[0-9.]+$/ && u == "MB") { mb += v; bytes = 1 }
      }
      n++
    }
    END { printf "%.0f\t%d\t%d", mb, n, bytes }'
}

arm() {   # $1 label, $2 block size bytes
  local label=$1 bs=$2
  local nrd T0 T1 wall MB N gotbytes agg
  nrd=$(awk -v b="$BYTES_PER_STREAM" -v s="$bs" 'BEGIN{printf "%d", b/s}')
  rm -f "$SPOOL"/*
  T0=$(date +%s.%N)
  local k i slot
  for ((k = 0; k < NS; k++)); do
    (
      slot=$(( (k * 997) % NSLOT ))
      for ((i = 0; i < nrd; i++)); do
        dd if="$L2" of=/dev/null bs="$bs" count=1 skip=$slot iflag=direct,fullblock \
           2>> "$SPOOL/$k.$i" &
        slot=$(( (slot + STRIDE) % NSLOT ))
        # no date in this loop; the read count is fixed, so the only fork is dd itself
        wait $! 2>/dev/null || true
      done
      wait
    ) &
  done
  wait
  T1=$(date +%s.%N)

  read -r MB N gotbytes <<< "$(sum_reads "$SPOOL")"
  wall=$(awk -v a="$T0" -v b="$T1" 'BEGIN{printf "%.3f", b-a}')
  local expect=$((NS * nrd))
  if [ "$gotbytes" -eq 0 ] || [ "$N" -lt $((expect * 95 / 100)) ]; then
    printf "  %-22s SHORT: %s of %s reads reported bytes -- not recording\n" "$label" "$N" "$expect"
    return 1
  fi
  agg=$(awk -v m="$MB" -v w="$wall" 'BEGIN{printf "%.0f", m/w}')
  local per
  per=$(awk -v a="$agg" -v n="$NS" 'BEGIN{printf "%.0f", a/n}')
  printf "  %-22s %6s MB/s aggregate, %5s per stream  (%.2f GB in %ss, %s reads of %s)\n" \
    "$label" "$agg" "$per" "$(awk -v m="$MB" 'BEGIN{printf "%.2f", m/1000}')" "$wall" "$N" "$bs"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$label" "$bs" "$NS" "$nrd" "$agg" "$per" "$MB" >> "$OUT/raw.tsv"
}

: > "$OUT/raw.tsv"
echo
echo "== smoke: both shapes must parse and must land in a plausible band"
arm "SMOKE_17.5MB" $SLOT    || exit 1
arm "SMOKE_4MB"    4194304    || exit 1
echo "  (both parsed and reported; continuing)"
: > "$OUT/raw.tsv"

sleep 120
for _ in $(seq 1 60); do
  l=$(cut -d' ' -f1 /proc/loadavg)
  awk -v a="$l" 'BEGIN{exit !(a<0.5)}' && break
  sleep 15
done
echo "idle: load=$(cut -d' ' -f1-3 /proc/loadavg)  $(date +%T)"

for pair in 1 2 3; do
  echo
  echo "[pair $pair] $(date +%T)"
  arm "A_17.5MB_s$pair" $SLOT    || exit 1
  arm "B_4MB_s$pair"    4194304    || exit 1
done

echo
echo "== penalty, and the verdict"
python3 - <<'PY'
import collections
d = collections.defaultdict(dict)
for line in open("reports/gateab_ab/v60_shape/raw.tsv"):
    label, bs, ns, nrd, agg, per, mb = line.rstrip("\n").split("\t")
    kind = "A" if label.startswith("A_") else "B"
    d[label.rsplit("_s", 1)[-1]][kind] = (float(agg), float(per), int(mb))
print(f"  {'pair':<6}{'17.5MB':>10}{'4MB':>10}{'penalty':>10}{'GB each':>10}")
pen = []
for p in sorted(d):
    if "A" in d[p] and "B" in d[p]:
        a, b = d[p]["A"], d[p]["B"]
        pen.append(b[0] / a[0])
        print(f"  {p:<6}{a[0]:>10.0f}{b[0]:>10.0f}{b[0]/a[0]:>9.2f}x{a[2]/1000:>9.2f}")
if pen:
    print()
    print(f"  penalty: min {min(pen):.2f}x  max {max(pen):.2f}x")
    v = "REAL" if min(pen) > 2.0 else ("ARTEFACT" if max(pen) < 1.5 else "INCONCLUSIVE")
    print(f"  verdict: {v}   (REAL if every pair >2x, ARTEFACT if every pair <1.5x)")
    if v == "REAL":
        print("  -> the shape penalty is real. Clustering experts by access order is the only")
        print("     lever left with magnitude, and it is inside the code.")
    elif v == "ARTEFACT":
        print("  -> no shape penalty. The 368 MB/s figure was a single-probe artefact and the")
        print("     1.30-1.58x from v58 is the whole story; the open question is why")
        print("     concurrency is 9 and not 16.")
PY
echo "end $(date +%T)"