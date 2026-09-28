#!/bin/bash
# The token column is all 0 (k3_trace_token was never called from the decode loop), so
# this aggregates all 8 tokens including the cold start. token 0's wall is known from the
# STEP table (85.49 s), which lets the steady-state estimate be backed out.
D=$(ls -dt /mnt/f/kimi-k3-in-c/reports/gateab_ab/v25_trace8-* | head -1)
CSV=$D/trace.csv
WALL=$(grep -aoE "[0-9]+ tokens in [0-9.]+ s" "$D/ctrl.log" | grep -oE "[0-9.]+ s$" | tr -d ' s')
T0=$(grep -aE "^0 +[0-9]+ +[0-9.]+" "$D/ctrl.log" | awk '{print $3}' | head -1)
echo "== $CSV"
echo "wall(total)=$WALL s   token0=$T0 s   tokens=8"
awk -F, -v wall="$WALL" -v t0="$T0" 'NR>1 {
    d=$6+0;
    if ($3=="compute") c+=d;
    else if ($3=="expert") e+=d;
    else if ($3=="trunk") t+=d;
    n++
  }
  END {
    nt=8;
    printf "\n-- all 8 tokens (token 0 included, so cold start inflates these) --\n";
    printf "  compute (includes expert) : %7.2f s/token\n", c/nt;
    printf "  expert  (inside compute)  : %7.2f s/token\n", e/nt;
    printf "  trunk                     : %7.2f s/token\n", t/nt;
    printf "  PURE arithmetic           : %7.2f s/token\n", (c-e)/nt;
    printf "\n-- steady state, using token0 wall %s as the cold-start excess --\n", t0;
    ss = (wall - t0)/7;
    printf "  steady-state wall         : %7.2f s/token\n", ss;
    printf "  expert share of compute   : %5.1f%%  (100%% = fully hidden by arithmetic)\n", 100*e/c;
  }' "$CSV"
echo
echo "== wall per token, from the STEP table:"
grep -aE "^[0-7] +[0-9]+ +[0-9.]+ " "$D/ctrl.log" | awk '{printf "  token %s  %6.2f s\n", $1, $3}'
echo
echo "== arithmetic per layer, all 8 tokens (top 5):"
awk -F, 'NR>1 && $3=="compute" { a[$2]+=$6 } END { for (k in a) printf "%8.2f s  layer %s\n", a[k]/8, k }' "$CSV" | sort -rn | head -5