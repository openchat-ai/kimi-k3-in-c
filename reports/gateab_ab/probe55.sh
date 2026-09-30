#!/bin/bash
# Check what disk statistics this WSL guest actually exposes before ab55.sh depends on it.
set -u
echo "== /proc/diskstats present?"
if [ -r /proc/diskstats ]; then
  echo "  yes"
  echo "  sdd7 row:"
  grep -E '[[:space:]]sdd7$' /proc/diskstats | sed 's/^/    /'
else
  echo "  NO -- /proc/diskstats missing"
fi

echo
echo "== what is in /proc that mentions the block device?"
for f in /proc/diskstats /proc/partitions /proc/mounts /proc/stat /proc/vmstat /proc/pressure/io; do
  if [ -r "$f" ]; then echo "  present  $f"; else echo "  MISSING  $f"; fi
done

echo
echo "== sdd7 in /proc/diskstats (any name)?"
[ -r /proc/diskstats ] && grep -c . /proc/diskstats || true
echo "  device names present:"
[ -r /proc/diskstats ] && awk '{printf "%s ", $3}' /proc/diskstats && echo

echo
echo "== sdd7 via /sys:"
ls -l /sys/block/sdd7 2>/dev/null | head -3 || echo "  no /sys/block/sdd7"

echo
echo "== which /dev nodes exist:"
ls -l /dev/sd* /dev/nvme* 2>/dev/null | head -10 || echo "  none"

echo
echo "== did the engine actually use /dev/sdd7? grep the last run's log:"
LOG=$(ls -td /mnt/f/kimi-k3-in-c/reports/gateab_ab/v52_counters/run-* 2>/dev/null | head -1)
[ -n "$LOG" ] && grep -aoE '/dev/[a-z0-9]+' "$LOG/ctrl.log" | sort -u | sed 's/^/    /' || echo "  no v52 log"
