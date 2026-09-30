#!/bin/bash
# v52: where does the 2.4x go? Counters in the read path, one run.
#
# Twelve external experiments failed to localise it. The read path is 1500 lines across 58
# functions, so the cheap move is to count in the code rather than infer from outside. Three
# counters in k3_io, printed by k3_io_report, split the time into parts that need different
# fixes:
#
#   stat_pread_s   summed across workers, time inside pread. bytes / this is the rate the
#                  device delivered under the engine's own access pattern, and it is
#                  directly comparable with the standalone probe's 2463 MB/s on the same
#                  file. Equal means the drive is not the limit.
#   stat_queue_s   submit -> dequeue. Large means workers were the constraint, i.e. the
#                  device was idle waiting to be asked.
#   stat_idle_s    workers that found every queue empty. Large means the pool was
#                  under-subscribed, i.e. the submitter could not keep up.
#
# Those three cannot all be small, and which one is large names the fix. Also timed: the
# submitter's own lock hold, and the worker's lock wait, so lock contention is separated from
# the pool being busy.
#
# Reported per tier, because the two streams are nothing alike -- the trunk stream is one
# request for a whole layer, expert reads are one 17.5 MB slot each -- and a combined total
# would hide whichever one is starving.
set -u
cd /mnt/f/kimi-k3-in-c
OUT=reports/gateab_ab/v52_counters
mkdir -p "$OUT"

sleep 240
for _ in $(seq 1 80); do
  l=$(cut -d' ' -f1 /proc/loadavg)
  awk -v a="$l" 'BEGIN{exit !(a<0.5)}' && break
  sleep 15
done
LOG="$OUT/run-$(date +%Y%m%d_%H%M%S)"
mkdir -p "$LOG"
{ echo "start : $(date +%T)"; echo "load  : $(cut -d' ' -f1-3 /proc/loadavg)"; } > "$LOG/state.txt"

unset K3_TRACE K3_NOKIO K3_L2_NATIVE K3_IO_NW0
./bin/k3 /model \
  --trunk /mnt/nvme/trunk_layers_out --embed-dir /mnt/nvme/embed \
  --trunk-gb 32 --cache-gb 15 \
  --ids 1008 --gen 3 --out "$LOG/ctrl.json" > "$LOG/ctrl.log" 2>&1
echo "EXIT=$?  end $(date +%T)" >> "$LOG/state.txt"

{
  echo "=== kio pool breakdown (the answer to 2.4x)"
  grep -aE "^kio tier" "$LOG/ctrl.log"
  echo
  echo "=== ledger for cross-check"
  grep -aE "s/token average|hit I/O|read from disk|phase2 i/o|expert phase split|trunk stream|^  read " "$LOG/ctrl.log"
  echo
  echo "=== totals from ctrl.json"
  python3 -c "
import json
d=json.load(open('$LOG/ctrl.json'))
t=d['trunk_bytes_read']; e=d['expert_bytes_read']; w=d['wall_seconds']
print('   trunk  %7.2f GB' % (t/1e9))
print('   expert %7.2f GB' % (e/1e9))
print('   total  %7.2f GB in %.1f s = %.0f MB/s' % ((t+e)/1e9, w, (t+e)/w/1e6))
print('   device does 2463 MB/s on the same file, so the total-rate gap is %.2fx'
      % (2463/((t+e)/w/1e6)))
"
} 2>&1 | tee "$OUT/summary.txt"
cat "$LOG/state.txt"
