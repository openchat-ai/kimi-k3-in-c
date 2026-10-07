#!/bin/bash
# loadavg 5.50 with only 1 runnable task means the rest are in uninterruptible sleep waiting on
# I/O. Find them, and get the diskstats read right this time:
#   major minor name reads merges sectors_read ms_reading writes merges sectors_written ...
# so reads_completed is $5 and writes_completed is $9, not $3.
set -u
echo "== D 状态（不可中断睡眠，通常是卡在 I/O）的进程"
ps -eo stat,pid,etimes,pcpu,comm --sort=stat | awk '$1 ~ /D/' | sed 's/^/  /'
N=$(ps -eo stat | grep -c '^D')
echo "  D 状态进程数：$N"

echo
echo "== 来宾 loadavg：$（不变量）$(cut -d' ' -f1-4 /proc/loadavg)"
echo "  字段：running/total = $(cut -d' ' -f4 /proc/loadavg)"
echo "  ★ running 远小于 loadavg，即多出来的部分在 D 状态"

echo
echo "== /dev/sdd 的 5 秒读写增量（修正字段：读=\$5 写=\$9）"
a=($(grep " sdd " /proc/diskstats | awk '{print $5, $9}'))
sleep 5
b=($(grep " sdd " /proc/diskstats | awk '{print $5, $9}'))
echo "  读完成  ${a[0]} -> ${b[0]}   +$(( ${b[0]} - ${a[0]} ))  ($(echo "scale=1; (${b[0]}-${a[0]})/5" | bc)/s)"
echo "  写完成  ${a[1]} -> ${b[1]}   +$(( ${b[1]} - ${a[1]} ))  ($(echo "scale=1; (${b[1]}-${a[1]})/5" | bc)/s)"

echo
echo "== 该设备的累计扇区读（$6 字段）与平均请求大小"
grep " sdd " /proc/diskstats | awk '{printf "  累计读扇区 %s，读请求 %s，平均 %.1f KB/请求\n", $6, $5, ($5>0 ? $6*512/$5/1024 : 0)}'

echo
echo "== 来宾进程 CPU 前 6"
ps -eo pcpu,etimes,comm --sort=-pcpu | head -7 | sed 's/^/  /'

echo
echo "== ROTA 标志的可靠性"
echo "  lsblk 报 ROTA=$(lsblk -no ROTA /dev/sdd 2>/dev/null | head -1)  （1 = 旋转盘）"
echo "  但 /mnt/nvme 实测吞吐约 1500 MB/s，远超机械盘上限，故该标志不可信"
echo "  ★ 记录此矛盾：宿主以为是 NVMe，WSL 认为是旋转盘"