#!/bin/bash
# Is anything else touching the NVMe that /mnt/nvme lives on?
# The idle gate in every ab*.sh reads /proc/loadavg, which reflects the WSL guest only. A
# Windows-side process doing I/O on the same physical device would be invisible to it, so the
# gate can pass while the disk is shared. This checks the device itself.
set -u
echo "== /mnt/nvme 对应的块设备"
lsblk -o NAME,SIZE,TYPE,MOUNTPOINT,ROTA 2>/dev/null | grep -E 'sdd|nvme|NAME' | sed 's/^/  /'

echo
echo "== 该设备 5 秒内的读写增量（单位：次）"
DEV=""
for d in sdd nvme0n1; do
  [ -b "/dev/$d" ] && DEV="$d" && break
done
if [ -z "$DEV" ]; then
  echo "  ★ 未找到块设备，人工核对"
else
  echo "  设备 /dev/$DEV"
  a=$(grep " $DEV " /proc/diskstats | awk '{print $3, $6, $10}')
  sleep 5
  b=$(grep " $DEV " /proc/diskstats | awk '{print $3, $6, $10}')
  echo "  读完成次数: $a  ->  $b"
  echo "  写完成次数: $a  ->  $b"
  python3 - "$a" "$b" <<'PY'
import sys
a = [int(x) for x in sys.argv[1].split()]
b = [int(x) for x in sys.argv[2].split()]
names = ["reads completed", "writes completed"]
for i, n in enumerate(names):
    d = b[i] - a[i]
    print("  %-18s +%d  (%.1f/s)" % (n, d, d / 5.0))
PY
fi

echo
echo "== 来宾 loadavg（含磁盘等待说明）"
cat /proc/loadavg

echo
echo "== WSL 里除引擎外是否有其他重 I/O 进程"
ps -eo pcpu,etimes,comm --sort=-pcpu | head -6 | sed 's/^/  /'