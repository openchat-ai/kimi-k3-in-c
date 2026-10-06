#!/bin/bash
# The one measurement that decides whether any further engineering is worth doing.
#
# Two claims currently rest on a single probe:
#   - "a slow tier charges a byte cost AND a serialization cost" (the paper's strengthened claim)
#   - "4M blocks reach 1600 MB/s but 17.5 MB scattered reads reach only ~368, so there is a
#    ~4x shape penalty, and clustering experts by access order is the only lever with magnitude"
#
# The 368 came from one probe of twelve concurrent 17.5 MB reads in which six completed in 0.07 s
# and six in 0.57 s. Dividing total bytes by the slow side of that distribution to get 368 MB/s
# is a judgement call about which reads to count. If it is wrong, the shape penalty is an artefact
# and the whole "only lever with magnitude" statement collapses -- the 1.30-1.58x from v58 would
# then be the entire story, and the work is essentially finished.
#
# So: measure the two shapes properly, paired, three times each, and let it decide.
#
#   shape A  17.5 MB scattered reads of experts.l2   -- what the engine does
#   shape B  4 MB blocks of the same file            -- what v55 measured the device at
#
# Same file, same flags, same stride discipline, same duration. If the penalty is real, A lands
# far below B; if A matches B, there is no shape penalty and the paper's claim needs the other
# half of its argument carried by the queue and sleep counters alone.
set -u
cd /mnt/f/kimi-k3-in-c
OUT=reports/gateab_ab/v60_shape
mkdir -p "$OUT"

L2=/mnt/nvme/experts.l2
SLOT=17547264
NSLOT=$(($(stat -c %s "$L2") / SLOT))
[ $(( $(stat -c %s "$L2") % SLOT )) -eq 0 ] || { echo "partial trailing slot"; exit 1; }
STRIDE=4096
[ $((NSLOT % STRIDE)) -ne 0 ] || { echo "stride not coprime with nslot"; exit 1; }
echo "geometry: $NSLOT slots x $SLOT, stride $STRIDE coprime"
echo "  (same file for both shapes, so the comparison isolates the request shape alone)"

# One output file per read. Twelve dd processes appending to one file truncated lines and cost a
# whole run once already (v57b smoke reported 11 of 12), and the evidence had been deleted.
SPOOL="$OUT/spool"; mkdir -p "$SPOOL"

sum_bytes() {   # total MB actually delivered, across all spool files
  awk '/copied,/ {
      for (i = 1; i <= NF; i++)
        if ($i ~ /^[0-9.]+$/ && $(i+1) == "MB") mb += $i
      n++
    } END { printf "%.0f\t%d", mb, n }' "$1"/*
}

arm() {   # $1 label, $2 block size in bytes, $3 streams, $4 seconds
  local label=$1 bs=$2 ns=$3 secs=$4
  rm -f "$SPOOL"/*
  local T0 T1 wall MB N agg per expect
  # At the v55 ceiling of 1600 MB/s this is how many reads of bs a stream should complete; a
  # 90% floor catches a stalled run without punishing a device that is merely slow.
  expect=$(awk -v s="$secs" -v b="$bs" 'BEGIN{printf "%.0f", 1600*s*ns/(b*1024*1024)}')
  T0=$(date +%s.%N)
  for ((k = 0; k < ns; k++)); do
    (
      end=$(( $(date +%s) + secs ))
      slot=$(( (k * 997) % NSLOT ))
      while [ "$(date +%s)" -lt "$end" ]; do
        dd if="$L2" of=/dev/null bs="$bs" count=1 skip=$slot iflag=direct,fullblock \
           2>> "$SPOOL/$k.$slot" &
        slot=$(( (slot + STRIDE) % NSLOT ))
      done
      wait
    ) &
  done
  wait
  T1=$(date +%s.%N)

  MB=$(sum_bytes "$SPOOL" | cut -f1); N=$(sum_bytes "$SPOOL" | cut -f2)
  wall=$(awk -v a="$T0" -v b="$T1" 'BEGIN{printf "%.3f", b-a}')
  if [ "$N" -lt $((expect * 9 / 10)) ]; then
    printf "  %-26s SHORT: %s reads against ~%s expected -- not recording\n" "$label" "$N" "$expect"
    return 1
  fi
  agg=$(awk -v m="$MB" -v w="$wall" 'BEGIN{printf "%.0f", m/w}')
  per=$(awk -v a="$agg" -v n="$ns" 'BEGIN{printf "%.0f", a/n}')
  printf "  %-26s %6s MB/s aggregate, %5s per stream  (%.1f GB in %ss, %s reads, bs=%s)\n" \
    "$label" "$agg" "$per" "$(awk -v m="$MB" 'BEGIN{printf "%.1f", m/1000}')" "$wall" "$N" "$bs"
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$label" "$bs" "$ns" "$secs" "$agg" "$per" >> "$OUT/raw.tsv"
}

: > "$OUT/raw.tsv"
echo
echo "== smoke"
arm "SMOKE_17.5MB_8s"  $SLOT 8 6 || exit 1
arm "SMOKE_4MB_8s"    4194304 8 6 || exit 1
: > "$OUT/raw.tsv"

sleep 150
for _ in $(seq 1 60); do
  l=$(cut -d' ' -f1 /proc/loadavg)
  awk -v a="$l" 'BEGIN{exit !(a<0.5)}' && break
  sleep 15
done
echo "idle: load=$(cut -d' ' -f1-3 /proc/loadavg)  $(date +%T)"

for pair in 1 2 3; do
  echo
  echo "[pair $pair] $(date +%T)"
  arm "A_17.5MB_s${pair}" $SLOT 8 45   || exit 1
  sleep 10
  arm "B_4MB_s${pair}"    4194304 8 45 || exit 1
  sleep 10
done

echo
echo "== per-pair comparison and the verdict"
python3 - <<'PY'
import collections
rows = [l.rstrip("\n").split("\t") for l in open("reports/gateab_ab/v60_shape/raw.tsv")]
d = collections.defaultdict(dict)
for label, bs, ns, secs, agg, per in rows:
    kind = "A" if label.startswith("A_") else "B"
    pair = label.rsplit("_s", 1)[-1]
    d[pair][kind] = (float(agg), float(per), bs)
print(f"  {'pair':<6}{'17.5MB agg':>12}{'4MB agg':>12}{'penalty':>10}   {'17.5MB/stream':>15}{'4MB/stream':>13}")
pen = []
for p in sorted(d):
    if "A" in d[p] and "B" in d[p]:
        a, b = d[p]["A"], d[p]["B"]
        pen.append(b[0] / a[0])
        print(f"  {p:<6}{a[0]:>12.0f}{b[0]:>12.0f}{b[0]/a[0]:>9.2f}x   {a[1]:>15.0f}{b[1]:>13.0f}")
if pen:
    print()
    print(f"  penalty: min {min(pen):.2f}x  max {max(pen):.2f}x  "
          f"spread {100*(max(pen)-min(pen))/ (sum(pen)/len(pen)):.0f}%")
    v = "REAL" if min(pen) > 2.0 else ("ARTEFACT" if max(pen) < 1.5 else "INCONCLUSIVE")
    print(f"  verdict: {v}  (REAL if every pair >2x, ARTEFACT if every pair <1.5x)")
PY
echo "end $(date +%T)"