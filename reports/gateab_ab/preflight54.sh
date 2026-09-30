#!/bin/bash
# Pre-flight for v54: confirm each arm's memory plan fits BEFORE the 25-minute run.
#
# v53 burned two of its six arms on a plan the engine refused: 69.34 GB against 57.79 GB
# available, discovered 26 seconds into each arm with no numbers. The plan is printed at
# startup, so this costs a second per arm to check instead of a run to discover.
set -u
cd /mnt/f/kimi-k3-in-c
AVAIL=$(awk '/MemAvailable/{printf "%d",$2/1048576}' /proc/meminfo)
echo "available: ${AVAIL} GB"
echo

fail=0
for spec in "A 32 15 0" "B 24 24 1" "C 24 24 0" "D 16 32 1"; do
  set -- $spec
  tag=$1; tg=$2; cg=$3; pd=$4
  extra=""
  [ "$pd" -gt 0 ] && extra="--prefetch-depth $pd"
  # timeout is not decoration: --gen 0 does not reliably return right after the plan, and
  # the 16/32 arm sat there for ten minutes during the first preflight. The plan is printed
  # before that point, so a short cap is enough to read it.
  out=$(timeout 45 ./bin/k3 /model \
    --trunk /mnt/nvme/trunk_layers_out --embed-dir /mnt/nvme/embed \
    --trunk-gb "$tg" --cache-gb "$cg" $extra \
    --ids 1008 --gen 0 --out /tmp/preflight.json 2>&1)
  planned=$(printf '%s' "$out" | awk '/TOTAL/{print $2; exit}')
  if [ -z "$planned" ]; then
    echo "  $tag  trunk=$tg arena=$cg pf=$pd  -- NO PLAN PRINTED (crashed?)"
    printf '%s\n' "$out" | tail -4 | sed 's/^/       /'
    fail=$((fail+1))
    continue
  fi
  # TOTAL is printed with two decimals, so the comparison has to be floating point. The
  # integer test silently fell through on every arm -- `[: 52.33: integer expected` -- and
  # reported FITS without ever having compared anything, which is how v53's failure would
  # have passed here too.
  status="FITS"
  if awk -v p="$planned" -v a="$AVAIL" 'BEGIN{exit !(p > a)}'; then
    status="TOO BIG"
    fail=$((fail+1))
  fi
  echo "  $tag  trunk=$tg arena=$cg pf=$pd  planned=${planned}GB avail=${AVAIL}GB  $status"
done

echo
if [ $fail -gt 0 ]; then
  echo "$fail arm(s) will not start. Do not schedule the full run."
  exit 1
fi
echo "all arms fit; safe to schedule"
