#!/usr/bin/env bash
# loop-serial A/B: standard per-token decode vs block-serial (grouped) schedule.
# Fair comparison: each config WARMUP-then-measure, so both start with a hot
# expert L2 (the measured run's L2 hit reflects reuse, not first-touch cost).
# One script, all numbers captured: speed, slow-layer (trunk) reads, fast-layer
# (expert L2) reads, output ids -- the paper's table.
#
#   benchmarks/loop-serial.sh <model_dir> [out_dir]
set -u
MODEL="${1:?usage: loop-serial.sh <model_dir> [out_dir]}"
OUT="${2:-reports/loop_serial_$(date +%Y%m%d_%H%M%S)}"
mkdir -p "$OUT"

# 30-token prompt, 12 layers, gen 4: slow-layer reads differ sharply between
# schedules (standard = layers x gen = 48, block-serial = layers x rounds = 12)
IDS=$(python3 -c "print(','.join(map(str, range(1000, 1030))))")
GEN=4
BLOCK=4
LAYERS=12
TSV="$OUT/loop_serial.tsv"
printf 'config\ts/token\ttrunk_binds\ttrunk_reads\ttrunk_GB\tl2_hit_pct\tl2_read_GB\tl2_write_GB\tout_ids\n' > "$TSV"

TRUNK=/mnt/nvme/trunk_layers_out
[ -d "$TRUNK" ] || TRUNK="$MODEL/trunk"
L2=/mnt/nvme/experts.l2
[ -f "$L2" ] || L2=""

BASE="$MODEL --ids $IDS --gen $GEN --incremental --tok $MODEL --layers $LAYERS \
  --trunk $TRUNK --trunk-gb 6 --cache-gb 8"
[ -n "$L2" ] && BASE="$BASE --l2 $L2 --l2-policy heat"

measure() { # $1 tag $2 extra...
  local tag="$1"; shift
  echo "== $tag =="
  # warmup: same config, gen 1, discards output. Fills the expert L2 so the
  # measured run below is a hot-cache comparison for BOTH arms.
  timeout 3600 ./bin/k3 $BASE --gen 1 "$@" --out "$OUT/${tag}_warm.json" \
    > "$OUT/${tag}_warm.log" 2>&1
  echo "  warmup rc=$?"
  local t0 t1
  t0=$(date +%s.%N)
  timeout 3600 ./bin/k3 $BASE "$@" --out "$OUT/$tag.json" > "$OUT/$tag.log" 2>&1
  local rc=$?
  t1=$(date +%s.%N)
  [ $rc -ne 0 ] && echo "  *** measure exit=$rc (timeout/crash), not a data point" && return
  local wall=$(echo "$t1 - $t0" | bc)

  local spt=$(grep -aoE '[0-9.]+ s/token average' "$OUT/$tag.log" | tail -1 | grep -aoE '[0-9.]+')
  local tb=$(grep -aoE 'binds [0-9]+, hits [0-9]+ \([0-9.]+%\), reads [0-9]+' "$OUT/$tag.log" | tail -1)
  local binds=$(echo "$tb" | grep -aoE 'binds [0-9]+' | grep -aoE '[0-9]+')
  local reads=$(echo "$tb" | grep -aoE 'reads [0-9]+' | grep -aoE '[0-9]+')
  local tgb=$(grep -aoE 'read [0-9.]+ GB in [0-9.]+ s' "$OUT/$tag.log" | tail -1 | grep -aoE '[0-9.]+ GB' | grep -aoE '[0-9.]+')
  local l2h=$(grep -aoE 'L2   resident=[0-9]+/[0-9]+ slots hit=[0-9.]+% read=[0-9.]+GB write=[0-9.]+GB' "$OUT/$tag.log" | tail -1)
  local hit=$(echo "$l2h" | grep -aoE 'hit=[0-9.]+%' | grep -aoE '[0-9.]+')
  local l2r=$(echo "$l2h" | grep -aoE 'read=[0-9.]+GB' | grep -aoE '[0-9.]+')
  local l2w=$(echo "$l2h" | grep -aoE 'write=[0-9.]+GB' | grep -aoE '[0-9.]+')
  local ids=$(python3 -c "import json;print(','.join(map(str,json.load(open('$OUT/$tag.json'))['generated_ids'])))" 2>/dev/null)
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$tag" "${spt:--}" "${binds:--}" "${reads:--}" "${tgb:--}" "${hit:--}" "${l2r:--}" "${l2w:--}" "${ids:--}" >> "$TSV"
  echo "  s/token=${spt:--} trunk_binds=${binds:--} reads=${reads:--} read=${tgb}GB L2 hit=${hit}% r=${l2r}GB w=${l2w}GB ids=$ids wall=${wall}s"
}

measure standard
measure loop_block${BLOCK} --loop-serial 1 --loop-block "$BLOCK"
# Third arm: n-gram --spec (exact, draft is a free lookup, ONE forward per round).
# Reads = T*n/(A+1): the exact path's only lever is the accepted run A, which the
# run prints as "--spec: N rounds, mean accepted run A". ids must equal standard.
measure spec_ngram --spec "$GEN"

echo
echo "===== RAW ====="
column -t "$TSV"
echo
echo "===== markdown ====="
{
  echo "# Block-serial vs standard decode — $(date -u +%Y-%m-%d)"
  echo
  echo "Prompt: 30 synthetic tokens, gen $GEN, $LAYERS layers, trunk BF8."
  echo "Arms: standard (read once/token), loop_block (read once/block, approximate),"
  echo "spec_ngram (n-gram draft, verified EXACT: ids must equal standard)."
  echo "Each arm runs warmup-then-measure so both start with a hot expert L2;"
  echo "slow layer = trunk (read once per token in standard, once per round in"
  echo "block-serial), fast layer = expert L2 cache."
  echo
  echo "| config | s/token | trunk binds | trunk reads | trunk GB | L2 hit% | L2 read GB | L2 write GB | out ids |"
  echo "|---|---:|---:|---:|---:|---:|---:|---:|---:|"
  tail -n +2 "$TSV" | while IFS=$'\t' read -r c s tb tr tg lh lr lw o; do
    echo "| $c | $s | $tb | $tr | $tg | $lh | $lr | $lw | $o |"
  done
  echo
  echo "Raw data: $TSV"
} > "$OUT/loop_serial.md"
cat "$OUT/loop_serial.md"