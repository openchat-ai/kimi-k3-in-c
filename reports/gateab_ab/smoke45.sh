#!/bin/bash
# v44 and v43 both reported five arms of 0 MB/s after 25 minutes each, and both causes were
# things a 20-second run would have exposed. So: build, then run the short form, and only
# schedule anything long once the short form has produced plausible numbers.
set -u
cd /mnt/f/kimi-k3-in-c
mkdir -p reports/gateab_ab/v45_drift
cc -O2 -std=gnu99 -D_GNU_SOURCE -Iinclude -Iinclude/k3 -pthread \
   reports/gateab_ab/drift45.c build/src/io/k3_io.o \
   -o reports/gateab_ab/v45_drift/drift45 2>&1 | head -10
[ -x reports/gateab_ab/v45_drift/drift45 ] || { echo "BUILD FAILED"; exit 1; }
echo "built ok"
echo
echo "--- geometry and clock self-checks run before any measurement; the run below is the"
echo "--- short smoke (one sample per series). Anything non-zero here means the probe works."
echo
timeout 600 reports/gateab_ab/v45_drift/drift45 2>&1
rc=$?
echo
echo "exit=$rc"
if [ $rc -ne 0 ]; then
  echo "RESULT: the short run did not complete cleanly -- do not schedule the long one"
  exit 1
fi
