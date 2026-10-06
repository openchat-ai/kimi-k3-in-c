#!/bin/bash
# The previous test was invalid: dd of=/dev/null discards the data, so it never allocates memory
# and proves nothing. Touch real anonymous pages instead.
#
# Strong prior that the cap will not bite: the root cgroup directory lists controllers, max.depth,
# max.descendants, pressure, procs and stat, but no memory.max, and /proc/cgroups has a memory
# line -- the controller exists but is not delegated into this namespace, which is the usual
# WSL2 behaviour. Confirm with a real allocation rather than inferring from a file listing.
set -u
cd /mnt/f/kimi-k3-in-c

echo "== 根 cgroup 目录里有没有 memory.max"
ls /sys/fs/cgroup | grep -i mem | sed 's/^/  /' || echo "  无任何 memory 相关文件"
echo "  已委派的控制器:"
cat /sys/fs/cgroup/cgroup.controllers 2>/dev/null | sed 's/^/    /'
echo "  子 cgroup 里是否有 memory.max:"
ls /sys/fs/cgroup/*/ 2>/dev/null | head -5 | sed 's/^/    /'

alloc() {   # $1 scope args (may be empty), $2 MB to touch
  local args="$1" mb="$2"
  # A bytearray that is written to forces the pages to be backed.
  python3 -c "
import sys
mb = $mb
try:
    b = bytearray(mb * 1024 * 1024)
    for i in range(0, len(b), 4096):
        b[i] = 1
    print('  分配并写入 %d MB: 成功' % mb)
except MemoryError:
    print('  分配并写入 %d MB: MemoryError' % mb)
    sys.exit(7)
" 2>&1 | sed 's/^/  /'
  return $?
}

echo
echo "== 无上限，分配并写入 1024 MB"
alloc "" 1024
echo "  退出码=$?"

echo
echo "== 上限 512 MB，尝试分配并写入 1024 MB"
if systemd-run --scope --quiet -p MemoryMax=512M python3 -c "
b = bytearray(1024*1024*1024)
for i in range(0, len(b), 4096): b[i] = 1
print('  上限 512MB 下分配 1024 MB: 成功  -> 上限被忽略')
" 2>&1 | sed 's/^/  /'; then
  echo "  => 上限未生效"
else
  echo "  => 上限生效（进程被杀或 OOM）"
fi

echo
echo "== 若确认不生效，v63 的替代方案"
echo "  引擎内存计划可压到 ≈26 GB：当前 32/8 档 TOTAL 45.34 GB，"
echo "  把 --trunk-gb/--cache-gb 之和降到约 20 GB 即 TOTAL ≈26 GB。"
echo "  但那只是让引擎少申请，不产生宿主侧回收压力，机制与 cgroup 上限不同；"
echo "  若用它跑出结果，必须在表注中写明'以内存计划降档替代硬上限'，不得称复现。"