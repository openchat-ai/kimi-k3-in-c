#!/bin/bash
cd /mnt/f/kimi-k3-in-c/reports
printf "%-32s %10s %12s %12s %10s\n" RUN s/tok trunk_read park_s I/O_share
for d in gateAB_20260926_074101 gateAB_20260926_075554 gateAB_20260926_080942 \
         gateAB_20260926_083311 gateab_ab/v1_nokio-20260926_134011 \
         gateab_ab/v0_base-20260926_121456 gateab_ab/v0_repeat-20260926_132450 \
         gateab_ab/v2_revert-20260926_141618 gateab_ab/v3_native-20260926_144135 \
         gateab_ab/v2_cold-20260926_150652 gateab_ab/v4_native-20260926_155617 \
         gateab_ab/v4pf-20260926_162650; do
  f="$d/summary.txt"
  [ -f "$f" ] || f="$d/ctrl.log"
  [ -f "$f" ] || continue
  st=$(grep -aoE "[0-9]+\.[0-9]+ s/token" "$f" | head -1 | cut -d' ' -f1)
  tr=$(grep -aoE "read 436\.45 GB in [0-9.]+ s" "$f" | head -1 | grep -oE "[0-9.]+ s$" | cut -d' ' -f1)
  pk=$(grep -aoE "\+ [0-9.]+ s parked" "$f" | head -1 | grep -oE "[0-9.]+")
  pk=${pk:-0.00}
  sh=$(grep -aoE "I/O share of wall clock: [0-9.]+%" "$f" | head -1 | grep -oE "[0-9.]+")
  printf "%-32s %10s %12s %12s %10s\n" "$(basename $d)" "${st:-?}" "${tr:-?}" "$pk" "${sh:-?}"
done