#!/bin/bash
# Smoke test for probe40 at 1/20 scale, and it must answer one question before the real run:
# are the R reads in a round actually CONCURRENT? If the threads serialise, every arm would
# report the same number and the whole sweep would be meaningless.
#
# Test: time one round at R=1 and at R=16 on the same data. If concurrency is real, R=16
# should complete in roughly the wall time of a single read, not 16x it.
set -u
cd /mnt/f/kimi-k3-in-c
python3 - <<'PY'
src = open("reports/gateab_ab/probe40.py").read()
src = src.replace('if __name__ == "__main__":\n    main()', '')
ns = {}
exec(compile(src, "probe40.py", "exec"), ns)

round_once = ns["round_once"]

print("=== concurrency check: one round, same data, growing R")
base = None
for R in (1, 2, 4, 8, 16):
    times = [round_once(R, 4242)[0] for _ in range(3)]
    med = sorted(times)[1]
    if base is None:
        base = med
    print("   R=%-3d  median %6.4f s   vs R=1: %5.2fx   aggregate %6.0f MB/s"
          % (R, med, med / base, R * 17547264 / med / 1e6))

print()
print("   VERDICT: R=16 taking about as long as R=1 means the reads overlap.")
print("   If R=16 took ~16x R=1, the threads are serialising and the sweep is void.")
PY
