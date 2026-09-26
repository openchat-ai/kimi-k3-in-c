#!/bin/bash
# Per-layer DBG stats for two runs. Print wall & pread cumulative distributions.
for d in /mnt/f/kimi-k3-in-c/reports/gateAB_20260926_074101 \
         /mnt/f/kimi-k3-in-c/reports/gateab_ab/v4_native-20260926_155617; do
  echo "===== $(basename $d)"
  log="$d/ctrl.log"
  echo "token count (L2 lines): $(grep -ac 'DBG getmany L2 ' $log)"
  # wall and pread per line
  awk '/DBG getmany/{gsub("nw=", "", $2); gsub("session:",""); for(i=1;i<=NF;i++){
      if($i ~ /^wall=/){split($i,a,"="); w+=a[2]; wn++; if(a[2]>wmax)wmax=a[2]; if(a[2]<wmin||wn==1)wmin=a[2]}
      if($i ~ /^pread=/){split($i,a,"="); p+=a[2]; pn++; if(a[2]>pmax)pmax=a[2]}
      if($i ~ /^nw=/){split($i,a,"="); nw+=a[2]}
  } scaled by 1; } END{
      printf "layers=%d  avg_wall=%.3f  (min=%.3f max=%.3f)  avg_pread=%.3f (max=%.3f)  avg_nw=%.2f\n",
             wn, w/wn, wmin, wmax, p/pn, pmax, nw/pn
      printf "ratio pread/wall avg: %.1fx  total_pread=%.1fs  total_wall=%.1fs\n", (p/wn)/(w/wn), p, w
  }' $log
done
echo "===== which binary 081: check for K3 gate strings"
grep -acE "parked on the expert gate|phase2" /mnt/f/kimi-k3-in-c/reports/gateAB_20260926_074101/ctrl.log