#!/bin/bash
# What the trace says: per-phase totals, where the wall goes, and the read/compute
# overlap that a single "I/O share" number hides.
D=$(ls -dt /mnt/f/kimi-k3-in-c/reports/gateab_ab/trace_smoke-* | head -1)
CSV=$D/trace.csv
echo "== $CSV"
awk -F, 'NR>1 {
    ph=$3; dur=$6+0; by=$7+0;
    n[ph]++; t[ph]+=dur; b[ph]+=by;
    if (dur>mx[ph]) { mx[ph]=dur; mxl[ph]=$2 }
    l1h[ph]+=$8+0; l1m[ph]+=$9+0; l2h[ph]+=$10+0; l2m[ph]+=$11+0;
    if (dur>0.05) t0=(t0==""||$4+0<t0)?$4+0:t0; t1=($5+0>t1)?$5+0:t1
  }
  END {
    printf "%-8s %6s %12s %14s %10s %10s\n","phase","rows","wall_s","bytes_GB","max_dur","max_layer"
    for (p in n) printf "%-8s %6d %12.2f %14.2f %10.2f %10s\n",p,n[p],t[p],b[p]/1e9,mx[p],mxl[p]
    printf "\nspan %.2f s (first event %.3f -> last %.3f)\n", t1-t0, t0, t1
    printf "\n== expert hit split (requests, not bytes)\n"
    printf "  L1 resident (no disk):  %d\n  L2 resident (disk):      %d\n  NVMe pool (disk):        %d\n", l1h["expert"], l2h["expert"], l2m["expert"]
    printf "\n== trunk: hits (RAM) vs misses (disk)\n"
    printf "  hits=%d misses=%d\n", l1h["trunk"], l1m["trunk"]
  }' "$CSV"
echo
echo "== first 24 events of token 0 (the shape of one layer):"
awk -F, 'NR>1 && $1==0' "$CSV" | head -24 | awk -F, '{printf "  L%-3s %-8s %7.3f -> %7.3f  %6.3fs  %8.2f MB\n",$2,$3,$4,$5,$6,$7/1e6}'