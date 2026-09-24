#!/usr/bin/env python3
import os, random, sys
sys.path.insert(0, "/mnt/f/kimi-k3-in-c/reports")
import probe_readshape as p

def oneshot(name, offs):
    os.system("sync; echo 3 > /proc/sys/vm/drop_caches")
    g, s = p.run_pattern(name, offs)
    print("quick %-12s %.2f GB %.2f s %.0f MB/s" % (name, g, s, g / s * 1000))
    return g / s

n = 200
random.seed(1)
a = sorted(random.sample(range(0, p.NCH // 2), n))
b = sorted(random.sample(range(p.NCH // 2, p.NCH), n))
ra = oneshot("16thr-rand", a)
rb = oneshot("1thr-sorted", b)
print("ratio %.2fx" % (rb / ra))