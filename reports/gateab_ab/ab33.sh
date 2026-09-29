#!/bin/bash
# Nail down whether the day's headline "-8.6%" (80.93 -> 73.96) is real.
#
# 80.93 came from v18_bigcache, measured before BENCH_PROTO.md existed: no load snapshot,
# no idle check, no repeat. 73.96 is v30's median of three runs each started below
# loadavg 1.0. So the headline compares an unregulated number against a regulated one, and
# the true gain could be 8.6%, or 4%, or nothing. v30's own spread is 3.4%, and 73.96
# sits at the top edge of it (71.45 / 73.98 / 73.96), which is exactly the shape of a
# number that was too generous to its own baseline.
#
# The missing arm is trunk 6 GB / cache 40 GB, run three times under the v30 protocol.
# No K3_TRACE here, deliberately: v30's 73.96 was traced off, and adding the tracer costs
# about 2.8% (v32 measured 74.91 with it on), which would contaminate the very gap being
# tested.
#
# The comparison arm (v30, trunk 32 / cache 15) was measured in an earlier session, not
# interleaved here. BENCH_PROTO asks for interleaving. If this run lands outside the band
# by more than the band itself, the session difference does not change the conclusion; if
# it lands inside, that is reported as inconclusive rather than rounded to a conclusion.
set -u
cd /mnt/f/kimi-k3-in-c
OUT=/mnt/f/kimi-k3-in-c/reports/gateab_ab/v33_base640
mkdir -p "$OUT"

wait_idle() {
  for _ in $(seq 1 120); do
    l=$(cut -d' ' -f1 /proc/loadavg)
    if awk -v a="$l" 'BEGIN{exit !(a<1.0)}'; then return 0; fi
    sleep 15
  done
  echo "WARN: loadavg stayed >=1.0 for 30min, proceeding anyway"
}

for rep in 1 2 3; do
  LOG="$OUT/rep$rep-$(date +%Y%m%d_%H%M%S)"
  mkdir -p "$LOG"
  wait_idle
  {
    echo "load_before=$(cut -d' ' -f1-3 /proc/loadavg)"
    echo "mem_before=$(awk '/MemAvailable/{printf "%.1f",$2/1048576}' /proc/meminfo)GB"
  } > "$LOG/baseline.txt"
  sync; echo 3 > /proc/sys/vm/drop_caches; sleep 2

  unset K3_TRACE K3_NOKIO K3_L2_NATIVE K3_IO_NW0
  echo "[v33] rep$rep start $(date +%T)  $(tr '\n' ' ' < "$LOG/baseline.txt")"
  /usr/bin/time -f "TIME_ELAPSED=%e" ./bin/k3 /model \
    --trunk /mnt/nvme/trunk_layers_out --embed-dir /mnt/nvme/embed \
    --trunk-gb 6 --cache-gb 40 \
    --ids 1008 --gen 8 --out "$LOG/ctrl.json" > "$LOG/ctrl.log" 2>&1
  echo "EXIT=$?  end $(date +%T)  load_after=$(cut -d' ' -f1-3 /proc/loadavg)" >> "$LOG/baseline.txt"
  echo "[v33] rep$rep done  $(grep -a 's/token average' "$LOG/ctrl.log")"
  sleep 20
done

echo "[v33] all 3 reps complete $(date +%T)"
