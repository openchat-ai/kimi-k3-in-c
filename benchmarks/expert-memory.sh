#!/usr/bin/env bash
# Judge-witness experiment: does a larger RAM expert cache (hot experts resident in
# memory) cut the per-token NVMe re-read and speed up steady-state decode?
#
#   benchmarks/expert-memory.sh <model_dir> <trunk_dir> <out_dir>
#
# Rationale (notes/importance-index / byteflow-matrix E-04, verdict):
#   The paper criterion requires reuse to land on the FASTEST reachable layer
#   (RAM). With --cache-gb 8 the RAM arena holds 448 slots = 0.54% of the expert
#   pool, so every token re-reads ~25.8 GB of experts from the NVMe L2 file
#   (R_nvme >> 1). If the Zipf-hot experts (~K=130 covers 95% of requests) fit in
#   RAM, R_nvme should drop toward 1 and steady-state s/token should fall.
#
#   Two rungs, same memory ceiling, cache 8 vs 15: the only difference is whether
#   the hot set can stay resident in RAM between tokens. 3 reps each, because the
#   documented run-to-run spread is 33% and a single sample proves nothing.
set -u
MODEL="${1:?usage: expert-memory.sh <model_dir> <trunk_dir> <out_dir>}"
TRUNK="${2:?}"
OUT="${3:?}"
REPS="${4:-3}"
GEN=8
IDS=158929,972,34143
# L1 replacement policy: lru (default) or heat (K3_L1_POLICY=heat). The paper
# criterion says reuse should land on the fastest layer; heat keeps frequently
# requested experts resident across tokens where LRU evicts them. A/B both arms
# on the SAME binary via the env switch.
L1POL="${L1_POLICY:-lru}"

command -v systemd-run >/dev/null 2>&1 || {
    echo "systemd-run not found. This harness needs it to impose a genuine memory ceiling;"
    echo "see benchmarks/memory-ladder.sh for why."
    exit 1
}
systemd-run --scope --user -q true 2>/dev/null || {
    echo "systemd-run --user does not work here."
    exit 1
}
[ -x ./bin/k3 ] || { echo "./bin/k3 not built, run 'make -j' first"; exit 1; }
[ -d "$MODEL" ] || { echo "no such model dir: $MODEL"; exit 1; }
[ -d "$TRUNK" ] || { echo "no such trunk dir: $TRUNK"; exit 1; }

mkdir -p "$OUT"
TSV="$OUT/experts.tsv"
printf 'cache_gb\tl1_policy\trep\ts_per_tok\tpeak_rss_gb\texpert_gb\tnvme_gb\tmiss_gb\tids\n' > "$TSV"

{
    echo "date     : $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "host     : $(uname -srm)"
    echo "cpu      : $(grep -m1 'model name' /proc/cpuinfo 2>/dev/null | cut -d: -f2- | sed 's/^ *//')"
    echo "cores    : $(nproc 2>/dev/null || echo '?')"
    echo "memtotal : $(awk '/MemTotal/{printf "%.1f GB", $2/1048576}' /proc/meminfo 2>/dev/null)"
    echo "k3       : $(./bin/k3 --version 2>&1 | head -1)"
    echo "reps/rung: $REPS"
    echo "gen      : $GEN"
    echo "ids      : $IDS"
    echo "l1_policy: $L1POL"
} > "$OUT/machine.txt"
cat "$OUT/machine.txt"
echo

# cache-gb 8 vs 15, same 26 GB memory ceiling. trunk-gb scaled so total fits.
rungs="8:6 15:6"

REF=""
REF_RUNG=""
DIVERGED=0
for rung in $rungs; do
    CA=${rung%%:*}; TR=${rung#*:}
    for r in $(seq 1 "$REPS"); do
        tag="${L1POL}_cache${CA}_r${r}"
        echo "== L1 ${L1POL} / cache ${CA} GB / trunk ${TR} rep ${r}/${REPS} =="

        K3_L1_POLICY="$L1POL" systemd-run --scope --user -q \
            -p MemoryMax=26G -p MemorySwapMax=0 \
            ./bin/k3 "$MODEL" --ids "$IDS" --gen "$GEN" \
            --trunk "$TRUNK" --trunk-gb "$TR" --cache-gb "$CA" --incremental \
            --l2 /mnt/nvme/experts.l2 --l2-policy heat \
            --out "$OUT/$tag.json" > "$OUT/$tag.log" 2>&1
        rc=$?

        if [ $rc -ne 0 ]; then
            if [ $rc -eq 137 ] || grep -qi 'out of memory\|oom-kill' "$OUT/$tag.log"; then
                printf '%s\t%s\t%s\tOOM\t-\t-\t-\t-\t-\n' "$CA" "$L1POL" "$r" >> "$TSV"
                echo "   did not fit, that is a result, not an error"
                continue
            fi
            echo "   *** FAILED with exit $rc, not an OOM, and not a data point ***"
            tail -5 "$OUT/$tag.log" | sed 's/^/   | /'
            exit 1
        fi

        SPT=$(grep -oE '[0-9.]+ s/token average' "$OUT/$tag.log" | tail -1 | awk '{print $1}')
        RSS=$(grep -oE 'PEAK RSS for the whole run: [0-9.]+' "$OUT/$tag.log" | tail -1 | awk '{print $7}')
        EGB=$(grep -oE 'read from disk: [0-9.]+ GB' "$OUT/$tag.log" | tail -1 | awk '{print $4}')
        NVG=$(grep -oE 'read [0-9.]+ GB from L2|read from sdd7: [0-9.]+ GB' "$OUT/$tag.log" | tail -1)
        MSG=$(grep -oE 'miss I/O   : [0-9]+ misses, [0-9.]+ GB' "$OUT/$tag.log" | tail -1)
        IDSO=$(python3 -c "import json,sys;print(','.join(map(str,json.load(open(sys.argv[1]))['generated_ids'])))" "$OUT/$tag.json" 2>/dev/null)

        if [ -z "$IDSO" ]; then
            echo "   *** could not read generated_ids from $OUT/$tag.json ***"
            exit 1
        fi
        if [ -z "$REF" ]; then
            REF="$IDSO"; REF_RUNG="L1 ${L1POL} cache ${CA} rep $r"
        elif [ "$IDSO" != "$REF" ]; then
            echo "   *** OUTPUT DIFFERS from $REF_RUNG, this is a bug ***"
            echo "       expected: $REF"
            echo "       got     : $IDSO"
            DIVERGED=1
        fi

        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
            "$CA" "$L1POL" "$r" "${SPT:--}" "${RSS:--}" "${EGB:--}" "${NVG:--}" "${MSG:--}" "$IDSO" >> "$TSV"
        echo "   ${SPT} s/token, peak RSS ${RSS} GB, expert ${EGB} GB"
    done
done

echo
column -t "$TSV"
echo

if [ "$DIVERGED" -ne 0 ]; then
    echo "FAIL: output was not identical across cache budgets."
    exit 1
fi
echo "Output identical. Machine details: $OUT/machine.txt"