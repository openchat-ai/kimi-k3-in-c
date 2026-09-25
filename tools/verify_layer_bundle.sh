#!/bin/bash
# Layer-bundle real-machine verification: auto-budget dry-run + 3-way timing + verdict.
# Uses the AUTO memory budget (the engine hands spare RAM to the expert arena itself;
# forcing --cache-gb starved it to 5 GB -> 0.34% TRUE hit. Auto at ~13-14 GB arena was
# measured at ~10% TRUE hit). Runs entirely on the PC. Usage:
#   MODEL=... TRUNK=... IDS=... bash tools/verify_layer_bundle.sh
set -uo pipefail

: "${MODEL:?set MODEL=... to the model dir}"
: "${TRUNK:?set TRUNK=... to the trunk dir}"
: "${IDS:?set IDS=... to the prompt ids file}"
RUN_GEN="${RUN_GEN:-20}"
SPEC_N="${SPEC_N:-4}"
LOGDIR="$(mktemp -d)"

echo "== 1/6 pull branch =="
git fetch origin
git switch -c perf/layer-bundle-preload origin/perf/layer-bundle-preload 2>/dev/null \
  || git switch perf/layer-bundle-preload 2>/dev/null \
  || git checkout -b perf/layer-bundle-preload origin/perf/layer-bundle-preload 2>/dev/null

echo "== 2/6 build =="
make all ARCH= CFLAGS="-O3 -std=gnu99 -Wall -Wextra -Wpointer-arith -Wshadow -Wvla -Wno-unused-parameter -Werror -fopenmp -pthread -ffp-contract=off" || { echo "BUILD FAILED"; exit 1; }

echo "== 3/6 dry-run calibration (AUTO budget; watch the 'auto budget' + 'C =' lines) =="
k3 "$MODEL" --trunk "$TRUNK" --layer-bundle --dry-run --ids "$IDS" --gen "$RUN_GEN" --spec "$SPEC_N" \
  | grep -E "auto budget|layer-bundle plan|C =|C_spec|resident "

run() {
    local name="$1"; shift
    local log="$LOGDIR/$name.log" s e
    s=$(date +%s.%N)
    "$@" > "$log" 2>&1
    e=$(date +%s.%N)
    awk -v a="$s" -v b="$e" -v g="$RUN_GEN" -v n="$name" \
        'BEGIN{printf "  %s: %.1f s/tok (%.0f tok/s)\n", n, (b-a)/g, g/(b-a)}'
    grep -E "TRUE resident hit rate|slots .* of .* arena|s/token average|hit I/O" "$log" \
      | sed 's/^/    /;s/l2cache \[final step\]//'
}

echo "== 4/6 (a) baseline: no --layer-bundle, auto budget =="
t1=$(run "a-baseline" k3 "$MODEL" --trunk "$TRUNK" --ids "$IDS" --gen "$RUN_GEN")
echo "$t1"

K3_LOOP_BLOCK="${K3_LOOP_BLOCK:-4}"
echo "== 5/6 (b) layer-bundle, auto budget, block-serial prefetch blk=$K3_LOOP_BLOCK =="
echo "(block-serial overlaps a whole block of trunk reads behind compute; a/b earlier ran with it OFF)"
t2=$(run "b-bundle" k3 "$MODEL" --trunk "$TRUNK" --ids "$IDS" --gen "$RUN_GEN" --layer-bundle \
      --loop-serial 1 --loop-block "$K3_LOOP_BLOCK")
echo "$t2"

echo "== 6/6 (c) layer-bundle + spec $SPEC_N, block-serial prefetch blk=$K3_LOOP_BLOCK =="
echo "(note: --spec drafts on n-gram repetition; short/non-repetitive text shows little gain)"
t3=$(run "c-bundle-spec" k3 "$MODEL" --trunk "$TRUNK" --ids "$IDS" --gen "$RUN_GEN" --layer-bundle \
      --spec "$SPEC_N" --loop-serial 1 --loop-block "$K3_LOOP_BLOCK")
echo "$t3"

if [ "$K3_VERIFY_BLOCK_SWEEP" = "1" ]; then
    K3_BLOCK_DEEP="${K3_BLOCK_DEEP:-8}"
    echo "== 6d/6 block-depth sweep: bundle with blk=$K3_BLOCK_DEEP (deeper read-ahead fills drive idle dips) =="
    t2d=$(run "d-bundle-blk$K3_BLOCK_DEEP" k3 "$MODEL" --trunk "$TRUNK" --ids "$IDS" --gen "$RUN_GEN" --layer-bundle \
          --loop-serial 1 --loop-block "$K3_BLOCK_DEEP")
    echo "$t2d"
fi

echo "== 6b/6 compute-floor probe (min + low-decile layer walls = all-memory compute) =="
compute_floor() {
    local log="$1"
    [ -f "$log" ] || return
    awk '/DBG getmany L/{ for(i=1;i<=NF;i++) if($i ~ /^wall=/) {v=substr($i,6); sub(/s/,"",v); if(v>0.001) print v} }' "$log" \
      | sort -n | head -20 \
      | awk '{n++; s+=$1; if(n==1) m=$1} END{if(n) printf "    min %.3f s/layer | lowest-20 avg %.3f s/layer -> compute floor ~%.1f s/token\n", m, s/n, s/n*92}'
}
echo "$(compute_floor "$LOGDIR/a-baseline.log")"
echo "$(compute_floor "$LOGDIR/b-bundle.log")"

# Effective whole-run bandwidth vs the 1.22 GB/s dual-stream drive ceiling: the gap is
# the drive-idle window a deeper block read-ahead can still absorb (the user's "消化等待").
bw() {
    local log="$1"
    [ -f "$log" ] || return
    awk '
        / s\/token average/ { for(i=1;i<=NF;i++) if($i=="average" && $(i-1)=="s/token") w=$1 }
        /GB in/ { for(i=1;i<=NF;i++) if ($i ~ /^[0-9.]+$/ && $(i+1)=="GB" && $(i+2)=="in" && $(i+3) ~ /^[0-9.]+$/) b+=$i }
        END{
            if (w+0>0 && b+0>0){
                e=b/w; r=(b>w*1.22)?b/1.22-w:0;
                printf "    effective %.2f GB/s over %.1f s/tok (moving %.1f GB/token; drive peak 1.22) -> still-absorbable ~%.1f s/tok\n", e, w, b, r
            }
        }
    ' "$log" 2>/dev/null || true
}
echo "$(bw "$LOGDIR/b-bundle.log")"

echo "== 7/7 verdict =="
echo "$t1"; echo "$t2"; echo "$t3"
awk -v b="$t2" -v c="$t3" 'BEGIN{
    if (c < 34)  print "PASS: (c) under 34 s/tok (spec active), record and stop";
    else if (b < 34) print "PASS: (b) already under gate; spec is bonus";
    else print "FAIL at current config. Next lever that COMPUTES with real teeth:";
         print "  split drives (probe: expert lane alone 2.5 GB/s, dual-stream 1.2 GB/s)";
         print "  -> or RAM/CXL full/partial residency. Logs: '$LOGDIR'";
}'

echo "== optional side-quest: cross-layer sha256 dedup probe =="
for f in "$TRUNK"/*layer*; do sha256sum "$f"; done 2>/dev/null \
  | awk '{print $1}' | sort | uniq -d | wc -l