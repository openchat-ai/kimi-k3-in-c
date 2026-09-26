#!/bin/bash
# quick sampler: k3 pid io + thread wchan distribution
PID=$(pgrep -x k3 | head -1)
echo "PID=$PID"
grep -E 'read_bytes|write_bytes|syscr|syscw' /proc/$PID/io 2>&1
echo "NTHR=$(ls /proc/$PID/task 2>/dev/null | wc -l)"
echo ---WCHAN---
for t in $(ls /proc/$PID/task); do
  w=$(cat /proc/$PID/task/$t/wchan 2>/dev/null)
  echo "$t:$w"
done | awk -F: '{print $2}' | sort | uniq -c | sort -rn | head -8
echo ---STAT---
cat /proc/$PID/stat | awk '{print "utime="$14" stime="$15" state="$3}'