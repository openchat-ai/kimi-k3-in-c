#!/bin/bash
# systemd-run exists and accepts -p MemoryMax=26G, but the cgroup view inside the scope reads
# 54.8 GB, the same as the host, and memory.max is not readable. That is consistent with WSL2
# not enforcing memory cgroup limits at all. If the cap does not bite, v63 becomes a second copy
# of v62's unconstrained result and the hour is wasted.
#
# Test it directly rather than inferring from /proc/meminfo: ask for 512 MB and try to allocate
# 1 GB. If the cap works the allocation dies; if it is ignored it succeeds.
set -u
cd /mnt/f/kimi-k3-in-c

echo "== cgroup 版本与挂载"
stat -fc '%T' /sys/fs/cgroup 2>/dev/null | sed 's/^/  文件系统类型: /'
grep -cE 'memory' /proc/cgroups 2>/dev/null | sed 's/^/  \/proc\/cgroups 中 memory 行数: /'
echo "  /sys/fs/cgroup 内容:"; ls /sys/fs/cgroup 2>/dev/null | head -6 | sed 's/^/    /'

echo
echo "== 直接读 memory.max"
for f in /sys/fs/cgroup/memory.max /sys/fs/cgroup/memory/memory.limit_in_bytes; do
  if [ -r "$f" ]; then echo "  $f = $(cat "$f")"; else echo "  $f 不可读或不存在"; fi
done

echo
echo "== 决定性测试：上限 512 MB，尝试分配 1 GB"
systemd-run --scope --quiet -p MemoryMax=512M \
  bash -c 'dd if=/dev/zero of=/dev/null bs=1M count=1024 2>&1 | tail -1; echo "  分配 1 GB 退出码=$?"' 2>&1 | \
  sed 's/^/  /' | head -6
echo
echo "== 对照：同样分配但不限额"
bash -c 'dd if=/dev/zero of=/dev/null bs=1M count=1024 2>&1 | tail -1; echo "  分配 1 GB 退出码=$?"' 2>&1 | \
  sed 's/^/  /' | head -4

echo
echo "== 结论判据"
if systemd-run --scope --quiet -p MemoryMax=512M bash -c 'dd if=/dev/zero of=/dev/null bs=1M count=1024' >/dev/null 2>&1; then
  echo "  上限被忽略 —— WSL2 未强制 memory cgroup。v63 不能用此法实现表 3 的条件。"
else
  echo "  上限生效 —— cgroup 限制可用，v63 可跑。"
fi

echo
echo "== 若不可用，还能怎么逼近 26 GB 硬上限"
echo "  ulimit -v 限制虚拟地址空间，对 mmap 密集的分配器有效但会误杀预留地址；"
echo "  引擎内存计划可压到 ≈26 GB（--trunk-gb/--cache-gb 之和 ≈20 GB），"
echo "  但那是减少计划容量，不产生回收压力，机制与 cgroup 上限不同。"
grep -aoE "TOTAL +[0-9.]+ GB" reports/gateab_ab/v62_policy/lru8_r1/ctrl.log 2>/dev/null | head -1 | sed 's/^/  当前 32\/8 档计划: /'