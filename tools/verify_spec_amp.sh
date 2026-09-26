#!/bin/bash
# Speculative-decode amplification (the "break the 63s floor" path).
# Two stages, both run entirely on the PC:
#   1. ZERO-model repetition estimate of the prompt (re-implements k3_run.c:416's
#      spec_draft semantics over $IDS) -> tells us whether --spec will fire at all.
#   2. Real --spec K runs (batched greedy verification amortizes the trunk read /K).
# Verdict vs the 34 s/tok gate. Usage:
#   MODEL=... TRUNK=... IDS=... bash tools/verify_spec_amp.sh
set -uo pipefail

: "${MODEL:?set MODEL=... to the model dir}"
: "${TRUNK:?set TRUNK=... to the trunk dir}"
: "${IDS:?set IDS=... to the prompt ids file}"
RUN_GEN="${RUN_GEN:-16}"
SPECS="${SPECS:-4 8 16}"
LOGDIR="$(mktemp -d)"
K3_LOOP_BLOCK="${K3_LOOP_BLOCK:-4}"
LAYERS="${LAYERS:-}"                 # e.g. LAYERS=50: deterministic sub-34 lever alongside spec
lw() { [ -n "$LAYERS" ] && printf -- "--layers %s " "$LAYERS"; }

echo "== 1/5 pull branch =="
git fetch origin
git switch -c perf/layer-bundle-preload origin/perf/layer-bundle-preload 2>/dev/null \
  || git switch perf/layer-bundle-preload 2>/dev/null \
  || git checkout -b perf/layer-bundle-preload origin/perf/layer-bundle-preload 2>/dev/null

echo "== 2/5 build =="
make all ARCH= CFLAGS="-O3 -std=gnu99 -Wall -Wextra -Wpointer-arith -Wshadow -Wvla -Wno-unused-parameter -Werror -fopenmp -pthread -ffp-contract=off" || { echo "BUILD FAILED"; exit 1; }

echo "== 3/5 repetition estimate (zero model runs; prompt-only LOWER bound) =="
bash tools/rep_estimate.awk "$IDS" || echo "estimator failed; continuing without it"

echo "== 4/5 spec amplification sweep: --spec K --incremental --layer-bundle (trunk read /K per sweep) =="
run() {
    local name="$1"; shift
    local log="$LOGDIR/$name.log" s e
    s=$(date +%s.%N)
    "$@" > "$log" 2>&1
    e=$(date +%s.%N)
    awk -v a="$s" -v b="$e" -v g="$RUN_GEN" -v n="$name" \
        'BEGIN{printf "  %s: %.1f s/tok (%.0f tok/s)\n", n, (b-a)/g, g/(b-a)}'
    grep -E "s/token average|--spec: .*mean accepted run|TRUE resident hit rate" "$log" | sed 's/^/    /'
}
best=0
for K in $SPECS; do
    t=$(run "spec$K" k3 "$MODEL" $(lw) --trunk "$TRUNK" --ids "$IDS" --gen "$RUN_GEN" \
         --spec "$K" --incremental --layer-bundle \
         --loop-serial 1 --loop-block "$K3_LOOP_BLOCK")
    echo "$t"
    st=$(echo "$t" | grep -oE '[0-9.]+ s/tok' | head -1 | tr -d ' s/tok')
    if awk -v s="$st" -v b="$best" 'BEGIN{exit !(s>0 && (b==0 || s<b))}'; then best="$st"; fi
done

echo "== 5/5 verdict =="
awk -v b="$best" 'BEGIN{
    if (b>0 && b<34)  print "PASS: spec-amp reaches "b" s/tok < 34. Record K, tune RUN_GEN up on user text.";
    else if (b>0)     print "FAIL at "b" s/tok. The estimator line above says whether the prompt rewards --spec;";
    else              print "no run numbers"; print "  if low repetition -> next: --draft-trunk (int8/qdq trunk, 94.2% teacher-forced agreement)";
    print "  Logs: '$LOGDIR'";
}'