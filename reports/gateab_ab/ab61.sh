#!/bin/bash
# Does the async burst help? ca0e9b9 ("hide the MoE down-projection under the expert read")
# and 3ea020c ("hide the shared expert behind the async burst") moved the engine from 65.21 to
# 76.72 s/token, which reads as a regression -- but 65.21 was one run and the platform's spread
# on identical source is 22.5%, so that comparison decides nothing.
#
# What makes this worth running is that the burst timings say there is something to win. Within
# a layer's 16-expert burst the first completion lands at about 0.096 s and the last at 0.24 s,
# while that layer's arithmetic is 0.087 s. Compute that could start on the early arrivals would
# finish at 0.183 s, before the last expert does -- about 73% of the burst's remaining time.
# That overlap is exactly what these two commits attempt, so whether they achieve it decides how
# much of the 1.33x is reachable.
#
# Build each side once and alternate the binaries. Rebuilding per arm would add 20 minutes of
# make for no benefit and would leave the tree churning.
#
# Decision rule, from BENCH_PROTO section 14: five interleaved pairs, and a verdict only if the
# paired difference reaches 10% on the primary metric. Primary is kio aggregate MB/s, because
# that is delivered bytes over measured wall and has held to 1-4% across ten runs, whereas
# s/token has spanned 22.5%. s/token is recorded but is not what the verdict rests on.
set -u
cd /mnt/f/kimi-k3-in-c
OUT=reports/gateab_ab/v61_burst
mkdir -p "$OUT"
START=$(git rev-parse --short HEAD)
echo "start HEAD=$START  $(date +%T)"
echo "$START" > "$OUT/orig_head.txt"

# Restore on every exit path, not just the happy one. The first attempt restored AFTER both
# builds, so a build failure left src/ at 4c664a4 and -- because make clean had already run --
# left no bin/k3 at all. A trap covers that, and re-running the script then works instead of
# failing on a dirty tree.
cleanup() {
  git checkout "$START" -- src include >/dev/null 2>&1
  make clean >/dev/null 2>&1
  make -j8 >/dev/null 2>&1
  echo "tree restored to $START, bin/k3 rebuilt ($(ls -l bin/k3 2>/dev/null | awk '{print $5}') bytes)"
}
trap cleanup EXIT

NO_BURST=4c664a4      # last commit before ca0e9b9; src includes the counter fix
BURST=3ea020c         # ca0e9b9 + 3ea020c; src identical to e4e206a

build() {   # $1 ref, $2 output binary path, $3 log label
  echo "-- building $1"
  git checkout "$1" -- src include 2>&1 | sed 's/^/   checkout: /'
  make clean >/dev/null 2>&1
  # Log name is a separate argument. Passing the output path and using it to build the log
  # path produced "$OUT/build-$OUT/k3_noburst.log", a nested path that does not exist, so the
  # redirect failed and make never ran -- the script reported BUILD FAILED and lost nine
  # minutes to a variable reused for two purposes.
  if ! make -j8 > "$OUT/build-$3.log" 2>&1; then
    echo "BUILD FAILED for $1 -- see $OUT/build-$3.log"; return 1
  fi
  local ymm; ymm=$(objdump -d bin/k3 | grep -c ymm)
  echo "   ymm=$ymm"
  # 323 rather than ~1430 is the stale-object failure that silently drops AVX2 to SSE, and it
  # would halve every rate in this table rather than show up as an error.
  if [ "$ymm" -lt 1000 ]; then echo "   DEGRADED AVX2 ($ymm) -- refusing to use this binary"; return 1; fi
  cp bin/k3 "$2"
  echo "   saved $2  ($(stat -c %s "$2") bytes, built from $1)"
}

build "$NO_BURST" "$OUT/k3_noburst" noburst || exit 1
build "$BURST"   "$OUT/k3_burst"   burst   || exit 1

# The trap restores the tree on the way out; nothing to do here.
echo

run() {   # $1 binary, $2 tag
  local LOG="$OUT/$2"
  mkdir -p "$LOG"
  unset K3_TRACE K3_NOKIO K3_L2_NATIVE K3_IO_NW0 K3_SPREAD_DBG
  "$1" /model \
    --trunk /mnt/nvme/trunk_layers_out --embed-dir /mnt/nvme/embed \
    --trunk-gb 32 --cache-gb 15 \
    --ids 1008 --gen 3 --out "$LOG/ctrl.json" > "$LOG/ctrl.log" 2>&1
  local spt agg g0 g1 slp con
  spt=$(grep -aoE "[0-9.]+ s/token average" "$LOG/ctrl.log" | head -1 | grep -oE "^[0-9.]+")
  agg=$(grep -aoE "aggregate [0-9]+ MB/s" "$LOG/ctrl.log" | head -1 | grep -oE "[0-9]+")
  g0=$(grep -aoE "group0: [0-9]+ reqs, [0-9.]+ GB \| per-stream [0-9]+" "$LOG/ctrl.log" | grep -oE "[0-9]+$")
  g1=$(grep -aoE "group1: [0-9]+ reqs, [0-9.]+ GB \| per-stream [0-9]+" "$LOG/ctrl.log" | grep -oE "[0-9]+$")
  slp=$(grep -aoE "sleep [0-9.]+ s in [0-9]+ waits \([0-9]+% of worker-time" "$LOG/ctrl.log" | grep -oE "\([0-9]+%" | tr -d "(%")
  con=$(grep -aoE "concurrency [0-9.]+x" "$LOG/ctrl.log" | head -1 | grep -oE "[0-9.]+")
  printf "  %-14s %6s s/tok  agg=%-5s g0=%-5s g1=%-4s sleep=%-3s%% conc=%s\n" \
    "$2" "$spt" "$agg" "$g0" "$g1" "$slp" "$con"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$2" "$spt" "$agg" "$g0" "$g1" "$slp" "$con" >> "$OUT/raw.tsv"
  # This must be an `if`, not a trailing `[ ... ] &&`. A false test as a function's last
  # statement makes the function return 1, and the caller's `|| exit 1` then kills the run --
  # which is exactly what happened: the first arm produced a good result (115.55 s/token) and
  # the script exited anyway, so the second arm's directory was never even created.
  if [ -z "$spt" ]; then
    echo "  $2 produced no s/token -- aborting"
    return 1
  fi
  if [ -z "$agg" ]; then
    echo "  $2 produced no aggregate counter -- the binary lacks the kio report, aborting"
    return 1
  fi
  return 0
}

: > "$OUT/raw.tsv"
sleep 180
for _ in $(seq 1 80); do
  l=$(cut -d' ' -f1 /proc/loadavg)
  awk -v a="$l" 'BEGIN{exit !(a<0.5)}' && break
  sleep 15
done
echo "idle: load=$(cut -d' ' -f1-3 /proc/loadavg)  $(date +%T)"

for p in 1 2 3 4 5; do
  echo "[pair $p] $(date +%T)"
  # Run both arms of a pair before moving on, and neither may silently skip.
  if ! run "$OUT/k3_noburst" "noburst_p$p"; then echo "noburst_p$p failed -- aborting"; exit 1; fi
  sleep 25
  if ! run "$OUT/k3_burst" "burst_p$p"; then echo "burst_p$p failed -- aborting"; exit 1; fi
  sleep 25
done

echo
echo "== paired differences (positive aggregate / negative s/token favours the burst)"
python3 - "$OUT/raw.tsv" <<'PY'
import sys, statistics
rows = [l.rstrip("\n").split("\t") for l in open(sys.argv[1])]
d = {}
for tag, spt, agg, g0, g1, slp, con in rows:
    p = tag.rsplit("_p", 1)[-1]
    d.setdefault(p, {})["burst" if tag.startswith("burst") else "noburst"] = \
        dict(spt=float(spt), agg=float(agg), g1=float(g1), slp=float(slp), con=float(con))
pairs = sorted(k for k in d if len(d[k]) == 2)
if not pairs:
    print("  no complete pairs"); sys.exit(1)
print(f"  {'pair':<5}{'agg nob':>9}{'agg burst':>11}{'d agg %':>9}"
      f"{'s/tok nob':>11}{'s/tok burst':>13}{'d s/tok %':>11}{'d g1 %':>9}")
for k in ("agg", "spt", "g1"):
    pass
for p in pairs:
    a, b = d[p]["noburst"], d[p]["burst"]
    print(f"  {p:<5}{a['agg']:>9.0f}{b['agg']:>11.0f}{100*(b['agg']-a['agg'])/a['agg']:>8.1f}%"
          f"{a['spt']:>11.2f}{b['spt']:>13.2f}{100*(b['spt']-a['spt'])/a['spt']:>10.1f}%"
          f"{100*(b['g1']-a['g1'])/a['g1']:>8.1f}%")
da = [100*(d[p]['burst']['agg']-d[p]['noburst']['agg'])/d[p]['noburst']['agg'] for p in pairs]
ds = [100*(d[p]['burst']['spt']-d[p]['noburst']['spt'])/d[p]['noburst']['spt'] for p in pairs]
dg = [100*(d[p]['burst']['g1']-d[p]['noburst']['g1'])/d[p]['noburst']['g1'] for p in pairs]

# Within-binary spread. This is the number that decides whether the run measured anything at
# all: if one binary's own arms span more than the effect, no number of pairs resolves it.
def spread(v):
    m = statistics.median(v)
    return (max(v) - min(v)) / abs(m) * 100 if m else float('inf')
sa = [d[p]['noburst']['agg'] for p in pairs]
sb = [d[p]['burst']['agg'] for p in pairs]
print()
print(f"  within-binary spread, aggregate:")
print(f"    noburst {min(sa):.0f}-{max(sa):.0f}  spread {spread(sa):.0f}%")
print(f"    burst   {min(sb):.0f}-{max(sb):.0f}  spread {spread(sb):.0f}%")
pa = spread(da)
print(f"  paired-difference spread: {pa:.0f}% of its own median")
print(f"    per-pair: {[f'{x:+.1f}' for x in da]}")

# The three outcomes are not interchangeable. "No difference" means the effect is confirmed
# below threshold and other grounds may decide. "Cannot measure" means the run is void and
# nothing may be decided from it. Conflating them is how a void run ended up recommending that
# two commits not be reverted "on performance grounds".
signs = {1 if x > 0 else (-1 if x < 0 else 0) for x in da}
flipped = len(signs) > 1
print()
if flipped or pa >= 100:
    print("  VERDICT: CANNOT MEASURE")
    print("    paired differences change sign, or their spread is at least as large as their")
    print("    median. The effect is NOT confirmed absent -- this run is void and nothing may")
    print("    be decided from it. See BENCH_PROTO 14.1.")
    print("    To resolve it: a genuinely idle window (all three loadavg readings below 1),")
    print("    more pairs, or both arms run concurrently so a pair is shorter than the drift.")
elif statistics.median(da) >= 10:
    print(f"  VERDICT: KEEP -- median paired aggregate difference {statistics.median(da):+.1f}%, "
          "at or above threshold, spread below it")
else:
    print(f"  VERDICT: REVERT -- median paired aggregate difference {statistics.median(da):+.1f}%, "
          "at or below threshold, spread below it")
PY
echo "end $(date +%T)"