#!/bin/bash
# The 6/40 arm stalls ~200 s on token 1 in five of six runs, and never in the one run
# that started from a genuinely quiet machine. The step function was hidden because the
# earlier correlation used whole-run totals, which averages a binary event into mush.
#
# Which stream stalls? Compare the runs' own I/O ledgers. A trunk stall shows up as read
# seconds and bind wall far above the clean run at similar byte counts; an expert stall
# shows up in phase2. Both are printed per run.
set -u
cd /mnt/f/kimi-k3-in-c

for d in reports/gateab_ab/v33_base640/rep1-* reports/gateab_ab/v33_base640/rep2-* \
         reports/gateab_ab/v33_base640/rep3-* reports/gateab_ab/v34_ab/t6c40_r1-* \
         reports/gateab_ab/v34_ab/t6c40_r2-* reports/gateab_ab/v34_ab/t6c40_r3-* \
         reports/gateab_ab/v34_ab/t32c15_r1-* reports/gateab_ab/v34_ab/t32c15_r3-*; do
  [ -f "$d/ctrl.log" ] || continue
  n=$(basename "$d" | cut -c1-18)
  t1=$(awk 'NR==2{print $1}' <<< "$(grep -aE '^\s*1\s+[0-9]+\s' "$d/ctrl.log" | head -1)")
  echo "=== $n   token1 = ${t1:-?}s"
  grep -aE "read .* GB in .* s \(.* pread\)|bind wall|phase2 i/o|trunk stream:|expert cache:" \
    "$d/ctrl.log" | sed 's/^/    /'
  echo
done
