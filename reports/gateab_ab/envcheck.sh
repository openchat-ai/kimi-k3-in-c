#!/bin/bash
echo "== CPU MHz (current) =="
grep -m4 "MHz" /proc/cpuinfo
echo "== load / uptime =="
cat /proc/loadavg; uptime
echo "== meminfo detail =="
grep -E "MemTotal|MemFree|MemAvailable|Buffers|^Cached|Dirty|Writeback" /proc/meminfo
echo "== page cache share of RAM =="
awk '/^Cached:/{c=$2} /^MemTotal:/{t=$2} END{printf "  Cached %.1f GB / MemTotal %.1f GB = %.0f%%\n", c/1048576, t/1048576, 100*c/t}' /proc/meminfo
echo "== cgroup cpu.max (WSL throttling) =="
cat /sys/fs/cgroup/cpu.max 2>/dev/null || cat /sys/fs/cgroup/cpu/cpu.cfs_quota_us 2>/dev/null
echo "== v11 progress =="
d=$(ls -dt /mnt/f/kimi-k3-in-c/reports/gateab_ab/v11_res29c20-* 2>/dev/null | head -1)
[ -n "$d" ] && grep -aE "^[0-7] +[0-9]+" "$d/ctrl.log" | tail -4