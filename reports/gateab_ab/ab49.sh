#!/bin/bash
# The comparison that was never actually made: engine and device, alternating, in one
# session.
#
# Every engine-versus-device number today came from different moments. The engine's
# 439 MB/s is from v41 at 17:54; the device's 2610 MB/s is from v47 at 09:47, eight hours
# apart, with the drive at an unknown thermal state in each. That is the same mistake as
# comparing a level against a level, just with a longer gap: the quantity is the difference
# between two numbers, so the difference inherits every difference between the moments they
# were taken.
#
# The size of the problem is already visible inside the device side alone: v48's zero-pause
# arm over 100 s gave 3044 MB/s while v47's continuous 420 s gave 2610 -- a 17% spread on a
# configuration that was nominally identical. So before hunting for the remaining cause, the
# gap has to be measured with the thermal state shared rather than assumed shared.
#
# Design: alternate engine and device, three pairs, both reading the same file with O_DIRECT
# at the same 11-way concurrency and the same 17547264-byte stride. The engine's figure is
# its own per-token hit-I/O ledger; the device's is the whole-run rate of the standalone
# probe. Pairwise ratios are what get reported, because a ratio formed from adjacent runs
# cancels whatever the drive was doing a minute earlier.
#
# The engine runs 3 tokens (~210 s) and the device probe is given the same 210 s, so each
# arm occupies a comparable thermal state. Token 0 of an engine run is cold; tokens 1 and 2
# are steady, and the ledger is per token, so token 2 is the one that gets compared.
set -u
cd /mnt/f/kimi-k3-in-c
OUT=reports/gateab_ab/v49_paired
mkdir -p "$OUT"

[ -x "$OUT/steady47" ] || cp reports/gateab_ab/v47_steady/steady47 "$OUT/steady47" 2>/dev/null
[ -x "$OUT/steady47" ] || { echo "need steady47 built"; exit 1; }

DEV_S=210
ENG_GEN=3

sleep 240
for _ in $(seq 1 80); do
  l=$(cut -d' ' -f1 /proc/loadavg)
  awk -v a="$l" 'BEGIN{exit !(a<0.5)}' && break
  sleep 15
done
{
  echo "start : $(date +%T)"
  echo "load  : $(cut -d' ' -f1-3 /proc/loadavg)"
} > "$OUT/state.txt"

for pair in 1 2 3; do
  D="$OUT/dev$pair"; mkdir -p "$D"
  echo "[v49] pair $pair  DEVICE first  $(date +%T)"
  "$OUT/steady47" "$DEV_S" 2>&1 | tee "$D/run.txt" | tail -2

  E="$OUT/eng$pair"; mkdir -p "$E"
  echo "[v49] pair $pair  ENGINE       $(date +%T)"
  unset K3_TRACE K3_NOKIO K3_L2_NATIVE K3_IO_NW0
  ./bin/k3 /model \
    --trunk /mnt/nvme/trunk_layers_out --embed-dir /mnt/nvme/embed \
    --trunk-gb 32 --cache-gb 15 \
    --ids 1008 --gen "$ENG_GEN" --out "$E/ctrl.json" > "$E/ctrl.log" 2>&1
  grep -aE "s/token average|hit I/O|read from disk|trunk stream" "$E/ctrl.log" \
    | sed 's/^/    /' | tee "$E/ledger.txt"
  echo "[v49] pair $pair done $(date +%T)"
  sleep 30
done

echo "end   : $(date +%T)" >> "$OUT/state.txt"
cat "$OUT/state.txt"
