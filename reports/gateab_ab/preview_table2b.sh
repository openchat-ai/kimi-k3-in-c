#!/bin/bash
# Preview: is table 2b now rebuildable, or does it still refuse to reconcile?
#
# The decisive test is per-token. For each decode step, sum the traced phase exposures
# (trunk + expert + compute) and compare against that step's own wall time, taken from
# the engine's stdout per-token line rather than from the trace. If they agree, the
# columns are self-consistent and a rebuilt table is honest. If they do not, no amount
# of editing produces a defensible table and the answer is to say so.
#
# Preview only -- rep2 and rep3 are still running. Reads a file the engine has already
# closed, and touches no NVMe, so it cannot perturb the measurement in flight.
set -u
cd /mnt/f/kimi-k3-in-c
D=$(ls -d reports/gateab_ab/v32_table2b/rep1-* | head -1)
T="$D/trace.csv"
echo "=== $D"
echo
echo "=== trace header"
head -1 "$T" | sed 's/^/   /'

echo
echo "=== per-token phase exposure (seconds), from the trace"
awk -F, 'NR>1 { e[$1]+=($7); if($3==1) t[$1]+=$7; else if($3==2) x[$1]+=$7; else if($3==3) c[$1]+=$7 }
END { printf "   %-6s %9s %9s %9s %11s\n","token","trunk","expert","compute","sum"
      for(i=0;i<8;i++) printf "   %-6d %9.2f %9.2f %9.2f %11.2f\n", i, t[i], x[i], c[i], t[i]+x[i]+c[i]
      s=0; for(i=0;i<8;i++) s+=t[i]+x[i]+c[i]
      printf "   %-6s %9.2f %9.2f %9.2f %11.2f\n","ALL", T_, X_, C_, s
      T_=0;X_=0;C_=0; for(i=0;i<8;i++){T_+=t[i];X_+=x[i];C_+=c[i]}
      printf "   %-6s %9.2f %9.2f %9.2f %11.2f\n","ALL", T_, X_, C_, T_+X_+C_ }' "$T"

echo
echo "=== engine's own per-token wall (the number the trace must match)"
grep -aE "^\s*[0-7]\s" "$D/ctrl.log" | sed 's/^/   /'

echo
echo "=== per-token bytes from the trace"
awk -F, 'NR>1 { b[$1]+=($8) } END { for(i=0;i<8;i++) printf "   token=%d  %.2f GB\n", i, b[i]/1e9 }' "$T"
