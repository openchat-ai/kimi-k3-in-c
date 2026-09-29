#!/usr/bin/env python3
"""Is the engine's 4.4x gap a code inefficiency, or just how this drive behaves on bursts?

The continuous-stream probe reads 1786 MB/s with 16 concurrent O_DIRECT reads at the
engine's own geometry, while the engine's phase-2 counter reports 410 MB/s. But the two
are not doing the same thing:

  probe    one continuous stream of 1196 slots, 21 GB, no pauses
  engine   93 layers, each reading about 11 slots (0.19 GB), then arithmetic, then the
           next layer -- burst, pause, burst, 93 times

If this drive degrades sharply on short bursts -- queue refill, SLC eviction between
bursts, the host giving up depth on a mostly-idle queue -- then the "4.4x inefficiency"
is a property of the drive's burst behaviour and not of the engine's read path. That has
to be excluded before anyone goes looking for a bug in k3_cache or k3_l2cache.

So this measures the same device, the same unit, the same 16 lanes, the same total
bytes, at four burst granularities, plus a variable pause between bursts. The arm whose
rate matches the engine's 410 MB/s identifies the regime the engine is actually in.

Per BENCH_PROTO: O_DIRECT, engine-exact unit from `expert L2 exact:` in the startup log,
warm-up discarded, n=5, arms interleaved, median with IQR/median and NOISY above 0.15.
"""
import mmap
import os
import statistics as st
import threading
import time

L2 = "/mnt/nvme/experts.l2"
NSLOT = 17096
SLOT = 17547264
LANES = 16

TARGET = int(21 * 1000 ** 3)          # 21 GB, the engine's per-token expert read
SLOTS_TOTAL = TARGET // SLOT         # 1196


def buf(n):
    return mmap.mmap(-1, n)


def run(burst_slots, pause_s, slots_total, seed):
    """LANES readers, each grabbing `burst_slots` slots then stopping, repeated."""
    fd = os.open(L2, os.O_RDONLY | os.O_DIRECT)
    try:
        bufs = [buf(SLOT) for _ in range(LANES)]
        per_lane_total = slots_total // LANES
        bursts = max(1, per_lane_total // burst_slots)
        counter = [0]
        lock = threading.Lock()

        def worker(i):
            s = (seed + i * 7) % NSLOT
            for _ in range(bursts):
                for _ in range(burst_slots):
                    if s >= NSLOT:
                        s -= NSLOT
                    os.preadv(fd, [bufs[i]], s * SLOT)
                    s = (s + 89) % NSLOT
                if pause_s:
                    time.sleep(pause_s)
            with lock:
                counter[0] += bursts * burst_slots

        th = [threading.Thread(target=worker, args=(i,)) for i in range(LANES)]
        t0 = time.monotonic()
        for t in th:
            t.start()
        for t in th:
            t.join()
        wall = time.monotonic() - t0
        for b in bufs:
            b.close()
        return counter[0] * SLOT / wall / 1e6
    finally:
        os.close(fd)


def arm_continuous():
    fd = os.open(L2, os.O_RDONLY | os.O_DIRECT)
    try:
        bufs = [buf(SLOT) for _ in range(LANES)]
        per = SLOTS_TOTAL // LANES
        got = [0]

        def worker(i):
            s = (7 * i) % NSLOT
            for _ in range(per):
                if s >= NSLOT:
                    s -= NSLOT
                os.preadv(fd, [bufs[i]], s * SLOT)
                s = (s + 89) % NSLOT
            got[0] += per

        th = [threading.Thread(target=worker, args=(i,)) for i in range(LANES)]
        t0 = time.monotonic()
        for t in th:
            t.start()
        for t in th:
            t.join()
        w = time.monotonic() - t0
        for b in bufs:
            b.close()
        return got[0] * SLOT / w / 1e6
    finally:
        os.close(fd)


def main():
    print("geometry: slot=%d B, aligned=%s, lanes=%d, total=%.2f GB"
          % (SLOT, SLOT % 4096 == 0, LANES, SLOTS_TOTAL * SLOT / 1e9))
    print("engine's per-layer expert event: ~11 slots (0.19 GB) x 93 layers\n")

    # burst_slots per lane per burst. 11 slots/lane x 16 lanes = 176 slots = 3.1 GB is
    # bigger than the engine's 0.19 GB/layer, so also include a finer arm.
    arms = [
        ("continuous (no pause)",      None,  0.0),
        ("burst 74 slots/lane",        74,   0.0),
        ("burst 12 slots/lane, 0s",    12,   0.0),
        ("burst 12 slots/lane, 1s",    12,   1.0),
        ("burst 3 slots/lane, 0s",     3,    0.0),
    ]

    for name, bs, ps in arms:                      # warm up, discarded
        if bs is None:
            arm_continuous()
        else:
            run(bs, ps, SLOTS_TOTAL, 3)
    print("warm-up done\n")

    acc = {n: [] for n, _, _ in arms}
    for k in range(5):
        for idx, (name, bs, ps) in enumerate(arms):
            seed = 211 * (k + 1) + idx
            mbs = arm_continuous() if bs is None else run(bs, ps, SLOTS_TOTAL, seed)
            acc[name].append(mbs)
        print("  sample %d/5" % (k + 1))

    print("\n=== MB/s, 5 samples, interleaved. engine phase-2 = 410 MB/s")
    print("   %-26s %8s %8s %8s %9s  %s"
          % ("arm", "median", "min", "max", "IQR/med", "verdict"))
    for name, _, _ in arms:
        v = sorted(acc[name])
        med = st.median(v)
        q = st.quantiles(v, n=4)
        iqr = (q[2] - q[0]) / med
        print("   %-26s %8.0f %8.0f %8.0f %9.3f  %s"
              % (name, med, min(v), max(v), iqr, "NOISY" if iqr > 0.15 else "usable"))

    cont = st.median(acc["continuous (no pause)"])
    print("\n=== which arm reproduces the engine's 410?")
    for name, _, _ in arms:
        m = st.median(acc[name])
        print("   %-26s %6.0f MB/s  = %.2fx the engine" % (name, m, m / 410.0))
    print()
    print("   If some burst arm lands near 410, the gap is drive behaviour under bursts")
    print("   and the engine is not the problem. If every arm stays far above 410, the")
    print("   gap is in k3_cache / k3_l2cache and the next step is to bisect the kio hop.")


if __name__ == "__main__":
    main()
