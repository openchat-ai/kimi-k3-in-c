#!/bin/bash
P=/proc/532
if [ ! -d "$P" ]; then echo K3-GONE; exit 0; fi
echo "start_sec   : $(awk '{print $22}' $P/stat)"
echo "now_sec     : $(awk '{printf "%d", $22 + $14/100 + $15/100 + 0.5}' $P/stat)"
echo "utime_ticks : $(awk '{print $14}' $P/stat)"
echo "stime_ticks : $(awk '{print $15}' $P/stat)"
echo "cutime_ticks: $(awk '{print $16}' $P/stat)"
echo "cstime_ticks: $(awk '{print $17}' $P/stat)"
echo "--- io:"
head -8 $P/io
echo "--- ctrl.log size: $(stat -c %s /mnt/f/kimi-k3-in-c/reports/gateab_ab/v2_cold-20260926_150652/ctrl.log 2>/dev/null)"
echo "--- load: $(cut -d' ' -f1-3 /proc/loadavg)"