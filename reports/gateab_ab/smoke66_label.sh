#!/bin/bash
# Does the new label print, and is hit_wall still sane after the rebuild?
# Same geometry as ab56.sh: 32 GB trunk / 15 GB cache, ids 1008, gen 3.
set -u
cd /mnt/f/kimi-k3-in-c || exit 9

for d in /mnt/nvme/trunk_layers_out /mnt/nvme/embed; do
  [ -d "$d" ] && [ -n "$(ls -A "$d" 2>/dev/null)" ] || { echo "FATAL: $d 缺失或为空，中止"; exit 5; }
done
echo "几何 ok"

sleep 30
for i in $(seq 1 60); do
  l=$(cut -d' ' -f1 /proc/loadavg)
  if awk -v a="$l" 'BEGIN{exit !(a<0.5)}'; then echo "idle: load=$l  $(date +%T)"; break; fi
  [ "$i" -eq 60 ] && { echo "★ 未达空闲，中止"; exit 3; }
  sleep 15
done

OUT=reports/gateab_ab/v66_label
mkdir -p "$OUT"
RUN="$OUT/run-$(date +%Y%m%d_%H%M%S)"
mkdir -p "$RUN"
./bin/k3 /model \
  --trunk /mnt/nvme/trunk_layers_out --embed-dir /mnt/nvme/embed \
  --trunk-gb 32 --cache-gb 15 \
  --ids 1008 --gen 3 --out "$RUN/ctrl.json" > "$RUN/ctrl.log" 2>&1
echo "引擎 rc=$?  $(date +%T)"
echo "run: $RUN"

echo
echo "== hit/miss I/O 行"
grep -aE "^  hit I/O|^  miss I/O" "$RUN/ctrl.log" | sed 's/^/  /'

echo
echo "== kio 段（字节量应仍一致）"
grep -aE "^kio tier0|^ +group[01]" "$RUN/ctrl.log" | sed 's/^/  /'

echo
echo "== 判定"
python3 - "$RUN/ctrl.log" <<'PY'
import re, sys, pathlib
t = pathlib.Path(sys.argv[1]).read_text(errors="replace")
ok = True

if "no misses this run" in t:
    print("  新标签已生效：misses == 0 时印为『no misses this run』")
else:
    m = re.search(r"miss I/O\s*:.*?in ([\d.]+) s", t)
    if m:
        print("  本轮有 miss，走原格式串（%.2f s），标签未触发属预期" % float(m.group(1)))
    else:
        print("  ★ 既无新标签也未匹配到 miss I/O 行"); ok = False

hw = re.search(r"hit I/O\s*:.*?in ([\d.]+) s \(wall\)", t)
ps = re.search(r"pread ([\d.]+) s", t)
if hw and float(hw.group(1)) > 0:
    h, p = float(hw.group(1)), float(ps.group(1)) if ps else 0.0
    print("  hit_wall = %.2f s  pread = %.2f s  比值 %.4f" % (h, p, h / p if p else 0))
    if p and not (0.5 <= h / p <= 2.0):
        print("  ★ 比值异常，需核对是否重复计入"); ok = False
else:
    print("  ★ hit_wall 为 0 或缺失"); ok = False

b = re.search(r"kio tier0: (\d+) reqs, ([\d.]+) GB", t)
if b:
    print("  kio 字节：%s reqs / %s GB（记录值 4595 / 216.66）" % (b.group(1), b.group(2)))
    if b.group(1) != "4595" or b.group(2) != "216.66":
        print("  ★ 与记录值不符 —— 几何或代码变了"); ok = False

print()
print("  判定：" + ("全部通过" if ok else "存在问题，见上"))
sys.exit(0 if ok else 1)
PY