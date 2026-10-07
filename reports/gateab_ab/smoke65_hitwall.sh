#!/bin/bash
# Does the report now show a non-zero hit_wall? That is the only test that matters: the symbol
# table carries no hit_wall because it is a struct member reached by offset, not an extern.
#
# Geometry is ab56.sh's unchanged: 32 GB trunk / 15 GB cache, ids 1008, gen 3.
set -u
cd /mnt/f/kimi-k3-in-c || exit 9

for d in /mnt/nvme/trunk_layers_out /mnt/nvme/embed; do
  [ -d "$d" ] && [ -n "$(ls -A "$d" 2>/dev/null)" ] || { echo "FATAL: $d 缺失或为空（几何不全，中止）"; exit 5; }
done
echo "几何 ok"

sleep 30
for i in $(seq 1 60); do
  l=$(cut -d' ' -f1 /proc/loadavg)
  if awk -v a="$l" 'BEGIN{exit !(a<0.5)}'; then echo "idle: load=$l  $(date +%T)"; break; fi
  [ "$i" -eq 60 ] && { echo "★ 15 分钟未达空闲，中止"; exit 3; }
  sleep 15
done

OUT=reports/gateab_ab/v65_hitwall
mkdir -p "$OUT"
RUN="$OUT/run-$(date +%Y%m%d_%H%M%S)"
mkdir -p "$RUN"
echo "run: $RUN"

./bin/k3 /model \
  --trunk /mnt/nvme/trunk_layers_out --embed-dir /mnt/nvme/embed \
  --trunk-gb 32 --cache-gb 15 \
  --ids 1008 --gen 3 --out "$RUN/ctrl.json" > "$RUN/ctrl.log" 2>&1
echo "引擎 rc=$?  $(date +%T)"

echo
echo "== L2 报告段"
grep -aA2 -E "^  hit I/O|^  miss I/O" "$RUN/ctrl.log" | sed 's/^/  /'

echo
echo "== kio 段（字节量应与既往一致）"
grep -aE "^kio tier0|^ +group[01]" "$RUN/ctrl.log" | sed 's/^/  /'

echo
echo "== 判定"
python3 - "$RUN/ctrl.log" <<'PY'
import re, sys, pathlib
t = pathlib.Path(sys.argv[1]).read_text(errors="replace")

hw = re.search(r"hit I/O\s*:.*?in ([\d.]+) s \(wall\)", t)
mw = re.search(r"miss I/O\s*:.*?in ([\d.]+) s \(wall\)", t)
ps = re.search(r"pread ([\d.]+) s", t)
if not hw:
    print("  ★ 未匹配到 hit I/O 行 —— 报告格式变了，人工核对")
    sys.exit(2)
h, m, p = float(hw.group(1)), (float(mw.group(1)) if mw else 0.0), (float(ps.group(1)) if ps else 0.0)
print("  hit_wall  = %.2f s   （修复前恒为 0.00）" % h)
print("  miss_wall = %.2f s" % m)
print("  pread     = %.2f s" % p)
print()
if h > 0:
    print("  判定：hit_wall 已非零，修复生效。")
    if p > 0:
        r = h / p
        print("  hit_wall / pread = %.4f" % r)
        if 0.5 <= r <= 2.0:
            print("  该比值应接近 1（hit_wall 与 pread 现在记的是同一批读的自身耗时）。")
        elif r < 1:
            print("  比值 < 1：pread 含 miss 侧累计，而 hit_wall 只含 hit 侧，故偏小，方向正确。")
        else:
            print("  比值 > 1，需要核�� hit_wall 是否被重复计入。")
else:
    print("  ★ hit_wall 仍为 0 —— 修复未生效，保留原始件并中止")
    sys.exit(1)
PY
echo "原始件：$RUN"