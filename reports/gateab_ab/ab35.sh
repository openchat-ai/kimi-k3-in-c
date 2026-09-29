#!/bin/bash
# Locate the trunk 6 GB / cache 40 GB token-1 stall.
#
# The observation: five of six 6/40 runs stall 150-297 s on token 1; the one run that did
# not (v33 rep1) is the one that started from a genuinely quiet machine (15min loadavg
# 0.14). The 32/15 arm never stalls this way (max/med 1.07-1.26).
#
# All six 6/40 runs did byte-identical work -- 436.45 GB read, 14.73 GB in phase 2, 744
# binds -- and the stall is invisible in the ledgers. bind wall is flat at ~12 s, so it is
# not the trunk. The entire phase-2 window is 55-69 s, so it cannot be phase 2 either.
# That leaves the single-expert get() path, which moves ~122 GB of the 137 GB and had no
# trace event and no timer of its own. k3_cache.c now emits one row per get() load, so
# this run should either show the stall directly or show it still unaccounted, which is
# also worth knowing.
#
# Two runs, because the stall is a 5-of-6 event and one run is not enough to trust.
set -u
cd /mnt/f/kimi-k3-in-c
OUT=/mnt/f/kimi-k3-in-c/reports/gateab_ab/v35_stall
mkdir -p "$OUT"

wait_idle() {
  sleep 240
  for _ in $(seq 1 80); do
    l=$(cut -d' ' -f1 /proc/loadavg)
    if awk -v a="$l" 'BEGIN{exit !(a<0.3)}'; then return 0; fi
    sleep 15
  done
  echo "WARN: loadavg stayed >=0.3, proceeding anyway"
}

for rep in 1 2; do
  wait_idle
  LOG="$OUT/rep$rep-$(date +%Y%m%d_%H%M%S)"
  mkdir -p "$LOG"
  { echo "1min/5min/15min = $(cut -d' ' -f1-3 /proc/loadavg)"
    echo "mem_avail = $(awk '/MemAvailable/{printf "%.1f",$2/1048576}' /proc/meminfo)GB"; } > "$LOG/state.txt"
  sync; echo 3 > /proc/sys/vm/drop_caches; sleep 2

  export K3_TRACE="$LOG/trace.csv"
  unset K3_NOKIO K3_L2_NATIVE K3_IO_NW0
  echo "[v35] rep$rep start $(date +%T)  $(cut -d' ' -f1-3 /proc/loadavg)"
  ./bin/k3 /model \
    --trunk /mnt/nvme/trunk_layers_out --embed-dir /mnt/nvme/embed \
    --trunk-gb 6 --cache-gb 40 \
    --ids 1008 --gen 8 --out "$LOG/ctrl.json" > "$LOG/ctrl.log" 2>&1
  echo "EXIT=$?  end $(date +%T)  load_after=$(cut -d' ' -f1-3 /proc/loadavg)" >> "$LOG/state.txt"
  echo "[v35] rep$rep done  $(grep -a 's/token average' "$LOG/ctrl.log")"
  echo "[v35] rep$rep token1 = $(grep -aE '^\s*1\s+[0-9]+\s' "$LOG/ctrl.log" | head -1 | awk '{print $3}')s  trace rows = $(($(wc -l < "$LOG/trace.csv") - 1))"
done

echo "[v35] both reps complete $(date +%T)"
