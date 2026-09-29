#!/bin/bash
# Why is the trunk 6 / cache 40 arm unstable? rep1 80.33, rep2 101.09, a 26% gap
# between two runs that both started at loadavg <1.0 with the same MemAvailable.
#
# The hypothesis to test is slot-level, not system-level: 40 GB is 2278 slots against a
# per-token working set the paper puts near 1472 keys, and heat-based eviction near a
# size boundary can thrash -- a run that keeps slightly more of the working set resident
# does dramatically less disk I/O than one that does not. If true, the arm is not "a
# slower config", it is a config sitting on a cliff edge, and its median is not a baseline
# for anything.
#
# Reads only the two completed reps. Touches no NVMe.
set -u
cd /mnt/f/kimi-k3-in-c
for d in reports/gateab_ab/v33_base640/rep1-* reports/gateab_ab/v33_base640/rep2-*; do
  echo "=== $(basename $d)"
  grep -aE "s/token average|TRUE resident|retained in RAM|evictions|expert cache:|PINNED|bytes read" "$d/ctrl.log" \
    | sed 's/^/   /'
  echo
done
echo "=== side by side"
printf "   %-6s %10s %14s %14s %12s\n" rep s/tok expert_GB retained evictions
for d in reports/gateab_ab/v33_base640/rep1-* reports/gateab_ab/v33_base640/rep2-*; do
  s=$(grep -aoE "[0-9.]+ s/token" "$d/ctrl.log" | head -1 | cut -d' ' -f1)
  g=$(grep -aoE "experts, whole run: [0-9.]+ GB" "$d/ctrl.log" | grep -oE "[0-9.]+" | head -1)
  r=$(grep -aoE "of [0-9]+ requests retained in RAM \([0-9.]+%\)" "$d/ctrl.log" | grep -oE "\([0-9.]+%\)" | tr -d '()')
  e=$(grep -aoE "\| [0-9]+ evictions" "$d/ctrl.log" | grep -oE "[0-9]+")
  printf "   %-6s %10s %14s %14s %12s\n" "$(basename $d | cut -c1-4)" "$s" "$g" "$r" "$e"
done
