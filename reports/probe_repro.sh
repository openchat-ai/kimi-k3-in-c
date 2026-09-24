#!/bin/bash
LOG=/mnt/f/kimi-k3-in-c/reports/lb_b_repro_20260924_112927
echo "== pid/k3 status =="
ps -o pid,etime,%cpu,rss,args -C k3 2>/dev/null | head -3 || echo "k3 not running"
echo "== log tail =="
tail -6 "$LOG/b.log" 2>/dev/null
echo "== STEP rows so far =="
grep -aE '^[ 0-9]+ +[0-9]+ +[0-9.]+ ' "$LOG/b.log" 2>/dev/null | tail -4
echo "== summary? =="
[ -f "$LOG/summary.txt" ] && cat "$LOG/summary.txt" || echo "still running"