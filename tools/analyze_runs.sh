#!/bin/bash
# Recompute the full per-run metrics from SAVED real-machine logs: no model re-run.
# Derives: auto budget arena, TRUE resident hit rate, s/token, compute floor
# (lowest-decile per-layer walls = all-memory compute), effective bandwidth and
# the still-absorbable wait (vs the 1.22 GB/s dual-stream ceiling). Also folds in
# the block-serial experiment TSVs if present. Usage:
#   tools/analyze_runs.sh [file-or-dir...]      (defaults: reports dir)
set -u

SEARCH="${1:-reports}"
if [ -d "$SEARCH" ]; then FILES=$(find "$SEARCH" -name "*.log" 2>/dev/null); else FILES=$(ls "$SEARCH" 2>/dev/null); fi
[ -z "$FILES" ] && { echo "no logs under $SEARCH"; exit 1; }

floor() {
    # lowest-decile per-layer walls -> all-memory compute floor (92 layers)
    awk '/DBG getmany L/{ for(i=1;i<=NF;i++) if($i ~ /^wall=/) {v=$i; sub(/^wall=/,"",v); sub(/s$/,"",v); if(v>0.001) print v}}
         END{ if (NR==0 || n==0) exit }
        ' "$1" | sort -n | awk '{n++; if(n==1) m=$1; if(n<=25) f25+=$1}
             END{ if (n>0) printf "min %.3f | lowest-25 avg %.3f s/layer -> compute floor %.1f-%.1f s/tok (n=%d)", m, f25/((n<25)?n:25), m*92, f25/((n<25)?n:25)*92, n }'
}

bw() {
    # Per-token bytes, dedup-correct: per-step lines (seconds 30-120) are per-token
    # snapshots of one step -> keep the LAST of each kind (expert "read from disk",
    # trunk "final trunk read"). Lines with seconds > 120 are run-cumulative (trunk
    # totals across N tokens) -> divide by token count. Absorbable wait vs the
    # 1.22 GB/s dual-stream ceiling.
    awk '
        / s\/token average/ { for(i=1;i<=NF;i++) if($i=="average" && $(i-1)=="s/token") w=$(i-2) }
        / tokens in /       { if (match($0, /[0-9]+ tokens in/) > 0) n=substr($0, RSTART, RLENGTH)+0 }
        /GB in/ {
          if ($0 ~ /phase2/) next
          for(i=1;i<=NF-3;i++) if ($i ~ /^[0-9.]+$/ && $(i+1)=="GB" && $(i+2)=="in" && $(i+3) ~ /^[0-9.]+$/) {
            t=$(i+3)+0
            if (t>=30 && t<=120) { if ($0 ~ /trunk/) trunk_l=$i; else exp_l=$i }
            else if ($i+0 > b2+0) b2=$i } }
        END{ if (w+0>0 && (exp_l+0 || trunk_l+0 || b2+0)) {
            b = exp_l + trunk_l + (n>0 ? b2/n : b2); r = (w > b/1.22) ? w - b/1.22 : 0;
            printf "one-token moved ~%.1f GB | eff BW %.2f GB/s (peak 1.22) -> absorbable %.0f s/tok", b, b/w, r } }
    ' "$1"
}

for f in $FILES; do
    case "$f" in
      *loop_serial.tsv) continue;;  # handled below
    esac
    ab=$(grep -m1 "auto budget" "$f" 2>/dev/null)
    true_hit=$(grep -m1 "TRUE resident hit rate" "$f" | sed -E 's/.*(TRUE resident hit rate [0-9.]+%).*/\1/' )
    st=$(grep -m1 "s/token average" "$f" | sed -E 's/.* ([0-9.]+) s\/token average.*/\1/')
    echo "== $f"
    [ -n "$ab" ] && echo "   $ab"
    [ -n "$true_hit" ] && echo "   $true_hit"
    [ -n "$st" ] && echo "   $st"
    fl=$(floor "$f"); [ -n "$fl" ] && echo "   compute: $fl"
    bwv=$(bw "$f"); [ -n "$bwv" ] && echo "   $bwv"
done

echo
echo "== block-serial experiments (standard vs loop_block4) =="
tsvs=$(find "$SEARCH" -name "loop_serial.tsv" 2>/dev/null)
[ -z "$tsvs" ] && echo "  none found" || for t in $tsvs; do
    awk -v t="$t" 'NR>1 && $1!="" && $2!="" {printf "  %s: %-13s %8.1f s/tok\n", t, $1, $2+0}' "$t"
done