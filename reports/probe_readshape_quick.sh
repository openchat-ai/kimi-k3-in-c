#!/bin/bash
# quick sanity of probe_readshape.py on a 200-chunk sample before the full run
set -u
cd /mnt/f/kimi-k3-in-c/reports
python3 - <<'EOF' 2>&1 | tee probe_quickcheck.log
import random, sys
sys.path.insert(0, ".")
import probe_readshape as p

n = 200
random.seed(1)
offs_a = sorted(random.sample(range(0, p.NCH // 2), n))
p.os.system("sync; echo 3 > /proc/sys/vm/drop_caches")
g, s = p.run_pattern("16thr-rand", offs_a)
print("quick 16thr: %.2f GB %.2fs %.0f MB/s" % (g, s, g / s * 1000))

offs_b = sorted(random.sample(range(p.NCH // 2, p.NCH), n))
p.os.system("sync; echo 3 > /proc/sys/vm/drop_caches")
g2, s2 = p.run_pattern("1thr-sorted", offs_b)
print("quick 1thr:  %.2f GB %.2fs %.0f MB/s" % (g2, s2, g2 / s2 * 1000))

print("ratio %.2fx" % ((g2 / s2) / (g / s)))
EOF
echo "[bg] quickcheck done $(date +%T)"