#!/bin/bash
# Layer-bundle real-machine verification: dry-run calibration + 3-way timing + verdict.
# Runs entirely on the PC; nothing is written back. Usage:
#   MODEL=... TRUNK=... IDS=... bash tools/verify_layer_bundle.sh
set -uo pipefail

: "${MODEL:?set MODEL=... to the model dir}"
: "${TRUNK:?set TRUNK=... to the trunk dir}"
: "${IDS:?set IDS=... to the prompt ids file}"
RUN_GEN="${RUN_GEN:-40}"
SPEC_N="${SPEC_N:-4}"
TRUNK_GB="${TRUNK_GB:-6}"
CACHE_GB="${CACHE_GB:-13.7}"

echo "== 1/6 pull branch =="
git fetch origin
git switch -c perf/layer-bundle-preload origin/perf/layer-bundle-preload 2>/dev/null \
  || git switch perf/layer-bundle-preload 2>/dev/null \
  || git checkout -b perf/layer-bundle-preload origin/perf/layer-bundle-preload 2>/dev/null

echo "== 2/6 build =="
make all ARCH= CFLAGS="-O3 -std=gnu99 -Wall -Wextra -Wpointer-arith -Wshadow -Wvla -Wno-unused-parameter -Werror -fopenmp -pthread -ffp-contract=off" || { echo "BUILD FAILED"; exit 1; }

echo "== 3/6 dry-run calibration =="
k3 "$MODEL" --trunk "$TRUNK" --trunk-gb "$TRUNK_GB" --cache-gb "$CACHE_GB" \
   --layer-bundle --dry-run --ids "$IDS" --gen "$RUN_GEN" --spec "$SPEC_N"
echo "--- check the four lines: plan / alive experts / C= / C_spec= ---"

run() {
    local name="$1"; shift
    local s e
    s=$(date +%s.%N)
    "$@"
    e=$(date +%s.%N)
    awk -v a="$s" -v b="$e" -v g="$RUN_GEN" -v n="$name" \
        'BEGIN{printf "%s: %.1f s/tok (%.0f tok/s)\n", n, (b-a)/g, g/(b-a)}'
}

echo "== 4/6 (a) baseline: no --layer-bundle =="
t1=$(run "(a) baseline" k3 "$MODEL" --trunk "$TRUNK" --ids "$IDS" --gen "$RUN_GEN")
echo "$t1"

echo "== 5/6 (b) layer-bundle =="
t2=$(run "(b) bundle" k3 "$MODEL" --trunk "$TRUNK" --cache-gb "$CACHE_GB" --ids "$IDS" --gen "$RUN_GEN" --layer-bundle)
echo "$t2"

echo "== 6/6 (c) layer-bundle + spec =="
echo "(note: --spec drafts on n-gram repetition; short/non-repetitive text shows little gain)"
t3=$(run "(c) bundle+spec" k3 "$MODEL" --trunk "$TRUNK" --cache-gb "$CACHE_GB" --ids "$IDS" --gen "$RUN_GEN" --layer-bundle --spec "$SPEC_N")
echo "$t3"

echo "== verdict =="
echo "$t1"; echo "$t2"; echo "$t3"
awk -v b="$t2" -v c="$t3" 'BEGIN{
    if (c < 34)  print "PASS: (c) under 34 s/tok (spec active), record and stop";
    else if (b < 34) print "PASS: (b) already under gate; spec is bonus";
    else print "FAIL: only two hardware levers left -> add RAM/CXL (-90% residency) or newer NVMe (B x3-8)";
}'

echo "== optional side-quest: cross-layer sha256 dedup probe =="
for f in "$TRUNK"/*layer*; do sha256sum "$f"; done 2>/dev/null \
  | awk '{print $1}' | sort | uniq -d | wc -l