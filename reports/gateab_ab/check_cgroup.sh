#!/bin/bash
# Does systemd-run exist in this WSL guest? Table 3's qualifier is a 26 GB cgroup cap, and
# without it v62's two policies converge (heat 25.50 vs LRU 25.83 GB/token) so the claim cannot
# be tested. Check before writing an hour-long run around it.
set -u
cd /mnt/f/kimi-k3-in-c
echo "== systemd-run 在不在"
if command -v systemd-run >/dev/null 2>&1; then
  echo "  路径: $(command -v systemd-run)"
else
  echo "  不存在"
fi
echo
echo "== 试跑一次带 MemoryMax 的 scope"
if systemd-run --scope --quiet -p MemoryMax=26G /bin/true 2>&1; then
  echo "  可用"
else
  echo "  不可用（rc=$?）"
fi
echo
echo "== 试读 cgroup 视图的内存上限"
systemd-run --scope --quiet -p MemoryMax=26G \
  bash -c 'echo "  $(awk "/MemTotal/{printf \"%.1f GB\", \$2/1048576}" /proc/meminfo) (cgroup 视图)"; cat /sys/fs/cgroup/memory.max 2>/dev/null | sed "s/^/  memory.max = /"' 2>&1 | head -5
echo
echo "== 宿主视角"
echo "  $(awk '/MemTotal/{printf "%.1f GB", $2/1048576}' /proc/meminfo)"
echo
echo "== 备选：能否用 ulimit 或 prlimit 限制"
bash -c 'ulimit -v 27801856 2>&1 && echo "  ulimit -v 可设"' | head -2
echo
echo "== 备选：引擎自己报内存计划，能否压低以制造压力"
grep -aoE "TOTAL +[0-9.]+ GB|available +[0-9.]+ GB" reports/gateab_ab/v62_policy/lru8_r1/ctrl.log 2>/dev/null | head -3 | sed 's/^/  /'