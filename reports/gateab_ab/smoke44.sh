#!/bin/bash
# Do not schedule a 25-minute run before the 20-second one works. v42 and v43 both produced
# five arms of 0 MB/s, and both times the cause was a defect that a 20-second foreground run
# would have shown immediately: a stale NSLOT, then a broken now_s().
#
# This runs one rep of one arm and asserts the rate is in a plausible band before anything
# long is scheduled.
set -u
cd /mnt/f/kimi-k3-in-c
mkdir -p reports/gateab_ab/v44_smoke
cc -O2 -std=gnu99 -D_GNU_SOURCE -Iinclude -Iinclude/k3 -pthread \
   reports/gateab_ab/kiohop.c build/src/io/k3_io.o \
   -o reports/gateab_ab/v44_smoke/kiohop 2>&1 | head -10
[ -x reports/gateab_ab/v44_smoke/kiohop ] || { echo "BUILD FAILED"; exit 1; }
echo "built ok"
echo
echo "--- run (this prints the clock and geometry self-checks, then the arms):"
timeout 120 reports/gateab_ab/v44_smoke/kiohop 2>&1 | head -14
echo
echo "--- verdict:"
out=$(timeout 120 reports/gateab_ab/v44_smoke/kiohop 2>&1)
if printf '%s' "$out" | grep -q "ABORTED"; then
  echo "   still short-reading -- geometry is still wrong"
  exit 1
fi
if printf '%s' "$out" | grep -qE "not in seconds"; then
  echo "   clock still wrong"
  exit 1
fi
if printf '%s' "$out" | grep -qE "^   A .*[0-9]{2,4} MB/s"; then
  echo "   OK: arm A reports a real rate; safe to schedule the full run"
else
  echo "   arm A still reports no usable rate:"
  printf '%s\n' "$out" | grep -E "^   (threads| A )" | head -4
  exit 1
fi
