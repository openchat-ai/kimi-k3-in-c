#!/bin/bash
echo "=== ps ==="
ps aux | grep -E "probe_duallane|python3" | grep -v grep
echo "=== procs ==="
for p in $(pgrep -f probe_duallane.py); do
  echo "--- pid $p ---"
  grep -E "State|Name" /proc/$p/status 2>/dev/null
  cat /proc/$p/wchan 2>/dev/null; echo
  cat /proc/$p/io 2>/dev/null
  echo
done