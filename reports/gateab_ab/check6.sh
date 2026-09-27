#!/bin/bash
# v6 liveness gate: 5 min in, the v5 wedge showed 0 IO + 41 futex threads with the log
# stuck at 104 bytes. Anything past that point is alive.
P=$(pgrep -f 'bin/k3 /model' | tail -1)
LOG=$(ls -dt /mnt/f/kimi-k3-in-c/reports/gateab_ab/v6_l2g1rw-* 2>/dev/null | head -1)/ctrl.log
[ -z "$P" ] && { echo "[chk] no k3 process"; exit 1; }
a=$(awk '/^rchar/{print $2}' /proc/$P/io); sleep 6; b=$(awk '/^rchar/{print $2}' /proc/$P/io)
echo "[chk] $(date +%T) pid=$P  io=$(( (b-a)/6/1024/1024 ))MB/s  log=$(stat -c%s $LOG)B"
echo "[chk] futex threads: $(for t in /proc/$P/task/*; do cat $t/wchan 2>/dev/null; echo; done | grep -c futex_wait_queue)/$(ls /proc/$P/task | wc -l)"
grep -aE "indexed|s/token|DBG getmany L2 " "$LOG" | tail -2