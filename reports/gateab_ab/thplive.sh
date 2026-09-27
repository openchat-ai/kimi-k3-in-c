#!/bin/bash
# Does the 40 GB arena actually get THP? madvise is advisory and its failure is
# swallowed, and a nearly-full 56 GB box may not find 2 MB contiguous blocks.
P=$(pgrep -f 'bin/k3 /model' | tail -1)
[ -z "$P" ] && { echo "[thp] k3 not running"; exit 1; }
echo "[thp] pid=$P $(date +%T)"
grep -E "^Rss|^AnonHugePages|^VmSize" /proc/$P/status
awk '/^Size:|^Rss:|^AnonHugePages:/{printf "  smaps %s %s kB\n", $1, $2}' /proc/$P/smaps_rollup 2>/dev/null
echo "[thp] system: $(grep AnonHugePages /proc/meminfo)"
echo "[thp] khugepaged: collapsed=$(cat /sys/kernel/mm/transparent_hugepage/khugepaged/pages_collapsed 2>/dev/null) scan_sleep=$(cat /sys/kernel/mm/transparent_hugepage/khugepaged/scan_sleep_millisecs 2>/dev/null) alloc_sleep=$(cat /sys/kernel/mm/transparent_hugepage/khugepaged/alloc_sleep_millisecs 2>/dev/null)"