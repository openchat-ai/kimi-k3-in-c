#!/bin/bash
P=$(pgrep -f 'bin/k3 /model' | tail -1)
echo "pid=$P  $(date +%T)"
for i in 1 2 3; do
  a=$(awk '/^rchar/{print $2}' /proc/$P/io); c=$(awk '/read_bytes/{print $2}' /proc/$P/io)
  ut=$(awk '{print $14+$15}' /proc/$P/stat)
  sleep 10
  b=$(awk '/^rchar/{print $2}' /proc/$P/io); d=$(awk '/read_bytes/{print $2}' /proc/$P/io)
  ut2=$(awk '{print $14+$15}' /proc/$P/stat)
  echo "sample$i rchar $(( (b-a)/10/1024/1024 ))MB/s  read_bytes $(( (d-c)/10/1024/1024 ))MB/s  cpu_ticks_delta $((ut2-ut))"
done
echo "== per-thread wchan (grouped):"
for t in /proc/$P/task/*; do cat $t/wchan 2>/dev/null; echo; done | sort | uniq -c | sort -rn
echo "== log size now: $(stat -c%s /mnt/f/kimi-k3-in-c/reports/gateab_ab/v5_l2g1-20260927_075655/ctrl.log)"
echo "== last log bytes:"; tail -c 200 /mnt/f/kimi-k3-in-c/reports/gateab_ab/v5_l2g1-20260927_075655/ctrl.log