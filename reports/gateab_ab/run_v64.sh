#!/bin/bash
# Launcher for the v64 schedstat probe, so that schtasks /TR carries no shell metacharacters.
set -u
cd /mnt/f/kimi-k3-in-c || { echo "cd failed"; exit 9; }
OUT=reports/gateab_ab/v64_probe.out
echo "v64 probe start $(date '+%F %T')  loadavg=$(cut -d' ' -f1-3 /proc/loadavg)"
bash reports/gateab_ab/probe_schedstat.sh > "$OUT" 2>&1
RC=$?
echo "v64 probe end   $(date '+%F %T')  rc=$RC"
echo "---- 输出 ----"
cat "$OUT"
echo "---- 引擎原始日志 ----"
cat reports/gateab_ab/v64_schedstat/run-*/ctrl.log 2>/dev/null | tail -40