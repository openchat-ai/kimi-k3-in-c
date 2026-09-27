#!/bin/bash
# Which of the four morning runs actually had the group-1 L2 hit path?
# git: 61cf381 (kio group time-slice) committed 09:22, but the runs started
# 07:41 / 07:55 / 08:09 / 08:33 -- so at most the later two could contain it,
# unless the work tree already had it uncommitted.
cd /mnt/f/kimi-k3-in-c/reports
for d in gateAB_20260926_074101 gateAB_20260926_075554 gateAB_20260926_080942 gateAB_20260926_083311 gateAB_20260926_085122; do
  f="$d/ctrl.log"
  [ -f "$f" ] || continue
  printf "%-30s " "$(basename $d)"
  # the hold shim prints this when it mounts; the group count comes from k3_io_init's
  # worker layout, so look for any kio line that names a group explicitly
  h=$(grep -acE "group|gate|hold" "$f")
  pk=$(grep -aoE "\+ [0-9.]+ s parked" "$f" | head -1 | grep -oE "[0-9.]+")
  printf "lines_mentioning_group_hold=%-4s parked=%-8s " "$h" "${pk:-none}"
  # kio debug output would be present only with K3_IO_DBG; check if any run has it
  grep -aq "DBG io submit" "$f" && printf "K3_IO_DBG=yes " || printf "K3_IO_DBG=no "
  echo
done
echo "== what the engine prints about groups at startup (current source):"
grep -n "group" /mnt/f/kimi-k3-in-c/src/io/k3_io.c | grep -iE "printf|fprintf" | head