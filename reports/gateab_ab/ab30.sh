#!/bin/bash
# Three consecutive runs of the winning configuration, each starting only when the box is
# quiet, with the operator idle for the whole run. The point is a number that can be
# quoted: v25 (68.54) and v29 (76.82) differ by 8.3 s on byte-identical work, and the only
# difference was how busy the machine was, so neither is trustworthy alone.
#
# Discipline (BENCH_PROTO v1 sections 6-7):
#   - wait for loadavg 1min < 1.0 before starting
#   - record a baseline before and after every run
#   - no sleep-with-polling in the foreground: this whole thing runs under schtasks
#   - the operator does nothing until this script prints "ALL DONE"
set -u
cd /mnt/f/kimi-k3-in-c
OUT=/mnt/f/kimi-k3-in-c/reports/gateab_ab/v30_repeat
mkdir -p "$OUT"
BASE=/mnt/f/kimi-k3-in-c/reports/gateab_ab/v30_repeat/base-$(date +%Y%m%d_%H%M%S)
mkdir -p "$BASE"

snap() {   # $1 = label
  echo "--- $1  $(date +%T)"
  echo "loadavg: $(cut -d' ' -f1-3 /proc/loadavg)"
  echo "MemAvailable: $(awk '/MemAvailable/{printf "%.1fGB",$2/1048576}' /proc/meminfo)"
  echo "trunk_avail: $(df -h /mnt/nvme | tail -1 | awk '{print $4}')"
}

wait_quiet() {
  for i in $(seq 1 60); do
    l=$(cut -d' ' -f1 /proc/loadavg | cut -d. -f1)
    if [ "$l" -lt 1 ]; then echo "[v30] loadavg1=$l, starting"; return 0; fi
    echo "[v30] waiting for quiet: loadavg1=$l ($i/60)"
    sleep 20
  done
  echo "[v30] WARN: never got below 1.0, starting anyway"
}

unset K3_NOKIO K3_L2_NATIVE K3_IO_NW0
for n in 1 2 3; do
  wait_quiet
  RUN="$OUT/run$n-$(date +%Y%m%d_%H%M%S)"
  mkdir -p "$RUN"
  snap "before run$n" >> "$RUN/baseline.txt"
  sync; echo 3 > /proc/sys/vm/drop_caches; sleep 2
  /usr/bin/time -f "TIME_ELAPSED=%e" ./bin/k3 /model \
    --trunk /mnt/nvme/trunk_layers_out --embed-dir /mnt/nvme/embed \
    --trunk-gb 32 --cache-gb 15 \
    --ids 1008 --gen 8 --out "$RUN/ctrl.json" > "$RUN/ctrl.log" 2>&1
  echo "run$n exit=$?" >> "$RUN/baseline.txt"
  sleep 5
  snap "after run$n" >> "$RUN/baseline.txt"
  s=$(grep -aoE "[0-9]+ tokens in [0-9.]+ s, [0-9.]+ s/token" "$RUN/ctrl.log" | grep -oE "[0-9.]+ s/token" | grep -oE "^[0-9.]+")
  echo "[v30] run$n = $s s/token  ($RUN)" | tee -a "$OUT/runs.txt"
  sleep 30
done

echo "ALL DONE $(date +%T)"
echo "== three runs =="
cat "$OUT/runs.txt"
python3 - <<'PY'
import re, statistics, glob
vals=[]
for line in open(glob.glob('/mnt/f/kimi-k3-in-c/reports/gateab_ab/v30_repeat/runs.txt')[0]):
    m=re.search(r'=\s*([0-9.]+)\s*s/token', line)
    if m: vals.append(float(m.group(1)))
if vals:
    print("values:", vals)
    if len(vals)>1:
        print("median: %.2f   min..max: %.2f..%.2f   spread: %.1f%%" % (
            statistics.median(vals), min(vals), max(vals),
            100*(max(vals)-min(vals))/statistics.median(vals)))
PY