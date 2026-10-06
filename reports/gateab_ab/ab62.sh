#!/bin/bash
# Table 3 of the paper (section 4.5) compares {LRU, heat} x {8 GB, 15 GB} and its numbers are
# cited again in the conclusion: "expert-stage READ falls from 25.83 to 20.99 GB/token, output
# speed up about 10%". None of the four output values appears anywhere in the ledger, and the
# table A.1 entry that should source it points at a byte-classification section instead. So the
# claim is currently unsourced, and the audit has to either reproduce it or strike it.
#
# Deciding on the byte column, not the speed column. The conclusion cites bytes ("READ 25.83 ->
# 20.99"), and bytes have held to the digit across nineteen runs while s/token spanned 22.5%.
# A byte measurement is decidable here; a 6-10% speed measurement is not, per BENCH_PROTO 14.1.
#
# Deviation to record: table 3 says gen=8 under a 26 GB cgroup cap. This runs gen=3 with no
# cgroup limit, because gen=8 costs 10.7 min per run and twelve runs would not fit, and because
# imposing a cgroup cap from a schtasks session is its own source of failure. A result at gen=3
# supports the direction; it does not by itself reproduce the gen=8 table, and that will be
# stated rather than glossed.
#
# Verdict logic is 14.1's: if the paired byte differences flip sign or their spread reaches
# their own median, the run is void and reported as CANNOT MEASURE.
set -u
cd /mnt/f/kimi-k3-in-c
OUT=reports/gateab_ab/v62_policy
mkdir -p "$OUT"
: > "$OUT/raw.tsv"

run() {   # $1 tag, $2 policy, $3 cache-gb
  local tag=$1 pol=$2 cg=$3
  local LOG="$OUT/$tag"
  mkdir -p "$LOG"
  unset K3_TRACE K3_NOKIO K3_L2_NATIVE K3_IO_NW0 K3_SPREAD_DBG
  ./bin/k3 /model \
    --trunk /mnt/nvme/trunk_layers_out --embed-dir /mnt/nvme/embed \
    --trunk-gb 32 --cache-gb "$cg" --l1-policy "$pol" \
    --ids 1008 --gen 3 --out "$LOG/ctrl.json" > "$LOG/ctrl.log" 2>&1
  # The engine prints expert bytes two ways; take the ledger-consistent one.
  local gb tok spt agg
  gb=$(grep -aoE "experts, whole run: [0-9.]+ GB read" "$LOG/ctrl.log" | grep -oE "^experts, whole run: [0-9.]+" | grep -oE "[0-9.]+")
  spt=$(grep -aoE "[0-9.]+ s/token average" "$LOG/ctrl.log" | head -1 | grep -oE "^[0-9.]+")
  agg=$(grep -aoE "aggregate [0-9]+ MB/s" "$LOG/ctrl.log" | head -1 | grep -oE "[0-9]+")
  tok=$(grep -aoE "[0-9]+ tokens in" "$LOG/ctrl.log" | head -1 | grep -oE "[0-9]+")
  if [ -z "$gb" ] || [ -z "$tok" ]; then
    echo "  $tag: no expert-byte figure in the log -- aborting (policy=$pol cache=$cg)"
    return 1
  fi
  local per; per=$(awk -v g="$gb" -v t="$tok" 'BEGIN{printf "%.2f", g/t}')
  printf "  %-16s policy=%-4s cache=%-3s  expert %6s GB / %s tok = %5s GB/token   %s s/tok\n" \
    "$tag" "$pol" "$cg" "$gb" "$tok" "$per" "${spt:-?}"
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$tag" "$pol" "$cg" "$per" "$spt" "$agg" >> "$OUT/raw.tsv"
  return 0
}

sleep 180
for _ in $(seq 1 80); do
  l=$(cut -d' ' -f1 /proc/loadavg)
  awk -v a="$l" 'BEGIN{exit !(a<0.5)}' && break
  sleep 15
done
echo "idle: load=$(cut -d' ' -f1-3 /proc/loadavg)  $(date +%T)"

# Interleave all four arms within each round, so a drift during the round hits every arm alike.
# The two pairs the paper's claim rests on are lru8-vs-heat8 and lru15-vs-heat15.
for r in 1 2 3; do
  echo "[round $r] $(date +%T)"
  run "lru8_r$r"  lru  8  || exit 1
  sleep 20
  run "heat8_r$r" heat 8  || exit 1
  sleep 20
  run "lru15_r$r" lru  15 || exit 1
  sleep 20
  run "heat15_r$r" heat 15 || exit 1
  sleep 20
done

echo
echo "== per-round expert GB/token, and the two pairs the paper's claim rests on"
python3 - <<'PY'
import statistics, collections
d = collections.defaultdict(list)
for line in open("reports/gateab_ab/v62_policy/raw.tsv"):
    tag, pol, cg, per, spt, agg = line.rstrip("\n").split("\t")
    arm = f"{pol}{cg}"
    d[arm].append(float(per))
print(f"  {'arm':<10}{'runs':>6}{'values GB/token':>34}{'median':>9}")
for a in ("lru8", "heat8", "lru15", "heat15"):
    if d[a]:
        v = d[a]
        print(f"  {a:<10}{len(v):>6}   {', '.join(f'{x:6.2f}' for x in v):>28}{statistics.median(v):>9.2f}")

def pair(a, b):
    if len(d[a]) != len(d[b]) or not d[a]:
        print(f"  {a} vs {b}: incomplete"); return
    diffs = [100*(x-y)/y for x, y in zip(d[a], d[b])]
    m = statistics.median(d[a]); mm = statistics.median(d[b])
    spread = (max(diffs)-min(diffs))/abs(statistics.median(diffs))*100 if statistics.median(diffs) else float('inf')
    flips = len({1 if x>0 else -1 for x in diffs}) > 1
    print(f"  {a} vs {b}: median {mm:.2f} vs {m:.2f} GB/token  paired {[f'{x:+.1f}' for x in diffs]}"
          f"  spread {spread:.0f}%  {'SIGN FLIPS' if flips else ''}")
    if flips or spread >= 100:
        print(f"      -> CANNOT MEASURE for this pair (BENCH_PROTO 14.1)")
    elif abs(statistics.median(diffs)) >= 5:
        print(f"      -> difference {statistics.median(diffs):+.1f}%, above a 5% byte threshold")
    else:
        print(f"      -> difference {statistics.median(diffs):+.1f}%, below a 5% byte threshold")
print()
print("  paper table 3 claims (gen=8, cgroup 26 GB):  LRU 25.83 -> heat 20.99 GB/token (-19%)")
print("                                            and  LRU 25.83 -> heat 17.44 GB/token (-32%)")
print("  this run is gen=3, no cgroup cap; the byte column is the decidable one, the")
print("  speed column is not, so no speed verdict is drawn.")
PY
echo "end $(date +%T)"