#!/bin/bash
# Rebuild table 2b from a clean run with WORKING token attribution.
#
# Why this exists. Table 2b's time/percentage columns were built from v25's K3_TRACE
# timeline, and k3_trace_token() was never called from the decode loop, so every row had
# token=0. "Steady state after removing the first token's cold start" was therefore not
# measurable. The table also failed its own arithmetic (2.4+49.2+16.8 = 68.4 s against a
# stated 66.12 s; real shares 3.6/74.4/25.4% against a stated 4/75/21% that merely sums to
# 100). None of that can be fixed by editing numbers -- it needs one clean run whose
# columns all come from the same measurement.
#
# Config is the 73.96 baseline exactly (trunk 32 GB / arena 15 GB, 16 workers, kio on,
# no prefetch, no native), prompt --ids 1008 --gen 8, so it is directly comparable to
# v23/v25/v29/v30 and to the cleaned-up paper text.
#
# Protocol, per BENCH_PROTO.md:
#   - three reps, each waiting for loadavg < 1.0 and dropping caches first
#   - loadavg and MemAvailable recorded before and after every rep
#   - K3_TRACE on, one CSV per rep
#   - nothing else touches the disk while this runs
#
# What the analysis may and may not conclude is in trace_table2b.sh.
set -u
cd /mnt/f/kimi-k3-in-c
OUT=/mnt/f/kimi-k3-in-c/reports/gateab_ab/v32_table2b
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

  export K3_TRACE="$LOG/trace.csv"
  unset K3_NOKIO K3_L2_NATIVE K3_IO_NW0
  echo "[v32] rep$rep start $(date +%T)  $(cat "$LOG/baseline.txt" | tr '\n' ' ')"
  /usr/bin/time -f "TIME_ELAPSED=%e" ./bin/k3 /model \
    --trunk /mnt/nvme/trunk_layers_out --embed-dir /mnt/nvme/embed \
    --trunk-gb 32 --cache-gb 15 \
    --ids 1008 --gen 8 --out "$LOG/ctrl.json" > "$LOG/ctrl.log" 2>&1
  echo "EXIT=$?  end $(date +%T)  load_after=$(cut -d' ' -f1-3 /proc/loadavg)" >> "$LOG/baseline.txt"
  echo "[v32] rep$rep done  $(grep -a 's/token average' "$LOG/ctrl.log")"
  sleep 20
done

echo "[v32] all 3 reps complete $(date +%T)"
