#!/bin/bash
echo "== THP (transparent hugepage) state =="
cat /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null
cat /sys/kernel/mm/transparent_hugepage/defrag 2>/dev/null
echo "== khugepaged counters =="
for f in /sys/kernel/mm/transparent_hugepage/khugepaged/*; do
  n=$(basename $f); v=$(cat $f 2>/dev/null)
  [ -n "$v" ] && echo "  $n = $v"
done
echo "== AnonHugePages in use =="
grep -E "AnonHugePages|HugePages_Total|HugePagesize" /proc/meminfo
echo "== per-process AnonHuge (k3 if running) =="
P=$(pgrep -f 'bin/k3 /model' | tail -1)
if [ -n "$P" ]; then grep -E "AnonHugePages|VmRSS" /proc/$P/status; fi
echo "== memory pressure =="
grep -E "MemFree|MemAvailable|Cached" /proc/meminfo
cat /proc/pressure/memory 2>/dev/null | head -3