#!/bin/bash
# What hardware performance counters does this box actually expose?
#
# The measurement discipline used all day (loadavg, /proc/meminfo) is an OS-level
# projection. Caladan (OSDI'20) and EyeQ (NSDI'13) do it differently: DRAM controller
# counters for bandwidth utilisation, per-core LLC miss counters to identify which
# tenant is the antagonist, sampled at 200 us-1 ms rather than gated on 1-minute averages.
#
# So the question is whether this box exposes the counters that discipline needs. Four
# things to determine, all read-only and none of which touch the NVMe:
#
#   1. Is there a PMU at all (perf_event_open available, core and uncore events listed)
#   2. Is the uncore IMC (memory controller) visible -- that is the one that would answer
#      "how much memory bandwidth is actually being consumed"
#   3. What memory-side events exist (LLC, offcore, bandwidth)
#   4. Are the Linux-native interfaces present even if perf is not installed:
#      perf_event_open, MSR, uncore PMU sysfs, Intel RDT / resctrl (which is precisely
#      "how is memory consumed, and by whom", and it has a control interface too)
set -u

echo "=== 1. CPU and PMU basics"
lscpu 2>/dev/null | grep -Ei 'model name|^cpu\(s\)|thread|core|socket|hypervisor|flags' \
  | sed 's/^\(.\{110\}\).*/\1.../' | head -8
echo
if [ -d /sys/bus/event_source/devices ]; then
  echo "   event_source devices: $(ls /sys/bus/event_source/devices | tr '\n' ' ')"
else
  echo "   NO /sys/bus/event_source/devices -- no PMU interface at all"
fi

echo
echo "=== 2. uncore / IMC (the memory controller -- the one that matters here)"
for d in /sys/bus/event_source/devices/uncore_imc_* /sys/bus/event_source/devices/uncore_pmc_*; do
  [ -d "$d" ] || continue
  n=$(basename "$d")
  cnt=$(find "$d/events" -type f 2>/dev/null | wc -l)
  echo "   $n  ($cnt event files)"
done
ls /sys/bus/event_source/devices 2>/dev/null | grep -iE 'imc|uncore' | sed 's/^/   found: /' \
  || echo "   none -- the memory controller is NOT exposed"

echo
echo "=== 3. memory-side core events (LLC / offcore / bandwidth)"
if [ -d /sys/bus/event_source/devices/cpu/events ]; then
  echo "   cpu events mentioning llc/offcore/mem:"
  ls /sys/bus/event_source/devices/cpu/events 2>/dev/null | grep -iE 'llc|offcore|mem' \
    | sed 's/^/     /' | head -12
  tot=$(ls /sys/bus/event_source/devices/cpu/events 2>/dev/null | wc -l)
  echo "   total cpu events: $tot"
fi

echo
echo "=== 4. native interfaces that do not need perf installed"
for f in /dev/cpu/0/msr /dev/perf_event /proc/sys/kernel/perf_event_paranoid; do
  if [ -e "$f" ]; then echo "   present: $f  ($(cat "$f" 2>/dev/null | head -1))"
  else echo "   absent : $f"; fi
done
echo
echo "   perf binary: $(command -v perf || echo 'not installed')"
echo "   resctrl / Intel RDT:"
if [ -d /sys/fs/resctrl ]; then
  echo "     /sys/fs/resctrl exists; groups: $(ls /sys/fs/resctrl | tr '\n' ' ')"
  for r in /sys/fs/resctrl/*/schemata; do
    echo "     $r:"; cat "$r" 2>/dev/null | sed 's/^/       /'
  done
  echo "     mbm_local_bytes:  $(ls /sys/fs/resctrl/mbm_local_bytes 2>/dev/null || echo n/a)"
  echo "     mbm_total_bytes:  $(ls /sys/fs/resctrl/mbm_total_bytes 2>/dev/null || echo n/a)"
else
  echo "     /sys/fs/resctrl ABSENT -- RDT not available"
fi

echo
echo "=== 5. what the memory controller looks like from the OS side (fallback only)"
echo "   vmstat fields that hint at reclaim-induced I/O:"
grep -E '^(pgscan|pgsteal|pgfault|pswpin|pswpout|pgmajfault|compact_)' /proc/vmstat \
  | sed 's/^/     /' | head -10
echo "   zone reclaim / throttle knobs:"
grep -E 'dirty_ratio|dirty_background_ratio|zone_reclaim_mode|swappiness|watermark' /proc/sys/vm \
  2>/dev/null | sed 's/^/     /' | head -6

echo
echo "=== 6. block-layer I/O accounting (what the NVMe path reports today)"
echo "   /proc/diskstats for the devices this work reads:"
for d in sdd sdd7; do
  [ -r /proc/diskstats ] || break
  awk -v D="$d" '$3 ~ D || $3 ~ "^"D"[0-9]+$" {printf "     %s: rd_ios=%s rd_merges=%s rd_sectors=%s rd_ticks=%s wr_ticks=%s in_flight=%s io_ticks=%s\n",$3,$4,$5,$6,$10,$14,$12,$13}' /proc/diskstats
done
grep -E '^(nr_requests|io_ticks|iodeps_ticks)' /proc/stat 2>/dev/null | sed 's/^/     /' | head -3
