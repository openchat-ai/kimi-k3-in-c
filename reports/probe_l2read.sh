#!/bin/bash
LOG=/mnt/f/kimi-k3-in-c/reports/lb_b_repro_20260924_112927
echo "== plan/PINNED/preload/arena lines =="
grep -aE 'PINNED|resident [0-9]+/|expert preload|expert arena|RING|trunk stream' "$LOG/b.log" | head
echo
echo "== per-token L2 read (cumulative GB) with delta =="
awk '/^  L2   resident=/{ g=0; for(i=1;i<=NF;i++){ if($i ~ /^read=/){x=$i; sub(/^read=/,"",x); sub(/GB$/,"",x); g=x+0} } if(last>0) printf "cum %8.2f GB  +%.2f\n", g, g-last; else printf "cum %8.2f GB (first)\n", g; last=g }' "$LOG/b.log"