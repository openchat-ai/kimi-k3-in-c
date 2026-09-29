#!/usr/bin/env python3
"""The device-side storage probe, rebuilt against the engine's actual geometry.

Why this is being rebuilt rather than re-run. spreadprobe.sh measured 1007 / 1058 /
1358 / 2926 MB/s and those numbers are the entire basis for "the device can do 1007+
with 16 concurrent streams, so the engine's 410 is a 2.5x inefficiency". Two things
were wrong with that measurement:

  1. It was a BUFFERED read. `dd if=$L2 of=/dev/null` with no iflag=direct, which
     BENCH_PROTO section 1 explicitly forbids because the engine opens experts.l2 with
     O_DIRECT (k3_l2cache.c:74) and buffered reads are inflated by the page cache.
  2. Its unit was wrong. bs=17600000 against the engine's l2.slot_bytes of 17547264, so
     every slot it read sat 52736 bytes further along; 100 slots in, it had drifted
     5.27 MB and was reading a part of the 300 GB file the engine never touches.

So the 2.5x gap may be entirely an artifact of the flag. This probe exists to find out
before anyone spends time on the engine's read path.

RESULT, and a caution about it. This run reported O_DIRECT 16 lanes = 1786 MB/s, against
the engine's 410, which reads as a 4.4x inefficiency. Do not use that multiple. v37_burst
repeats the identical continuous arm -- same 16 lanes, same O_DIRECT, same 21 GB -- and got
1214 MB/s, 47% lower, with IQR 0.477 against this run's 0.030. Four of v37's five arms
came out NOISY by the IQR/median > 0.15 rule in section 3. The device-side denominator
therefore has a run-to-run swing larger than the quantity being measured, and the only arm
that was stable anywhere (v37's burst-12-with-1s-pause, IQR 0.035) read 1110 MB/s. The gap
is real at 2.7x or more; the magnitude is not determinable at this measurement quality.
See section 4: no multiple may be quoted until the probe is reproducible.

Design, per BENCH_PROTO:
  - O_DIRECT, matching k3_l2cache.c:74
  - the engine's exact unit and offset stride, taken from the engine's own startup line
    (`expert L2 exact: nslot=17096 slot_bytes=17547264`) rather than assumed
  - each sample moves ~21 GB per lane-group, the same order as the engine's per-token
    expert read, so a short sample cannot flatter the device
  - warm up and discard before sampling
  - n=5 per arm, arms interleaved so any drift is shared
  - report median and IQR/median; arms above 0.15 are NOISY and support no ratio

The buffered arm is kept deliberately. It is the control: the same offsets, the same
size, the same concurrency, differing only in the flag -- which is exactly the
difference between the historical numbers and the engine's.
"""
import mmap
import os
import statistics as st
import sys
import time

L2 = "/mnt/nvme/experts.l2"
NSLOT = 17096
SLOT = 17547264          # engine's exact l2.slot_bytes
ALIGN = 4096
assert SLOT % ALIGN == 0

# Bytes per sample per arm. 21 GB matches the engine's per-token expert read
# (21.03 GB in 50.31 s = 418 MB/s), so the probe and the engine move comparable volumes
# and neither is measured on a trivially short burst.
GB = 1000 ** 3
TARGET = int(21 * GB)
SLOTS_PER_SAMPLE = TARGET // SLOT          # ~1197 slots


def buf(nbytes):
    m = mmap.mmap(-1, nbytes)
    return m


def sample(lanes, direct, seed_base, slots_total):
    """lanes concurrent readers, each pulling whole slots, disjoint regions per lane."""
    per = slots_total // lanes
    bufs = [buf(SLOT) for _ in range(lanes)]
    flags = os.O_RDONLY | (os.O_DIRECT if direct else 0)
    fd = os.open(L2, flags)
    try:
        results = [None] * lanes

        def worker(i):
            t0 = time.monotonic()
            n = 0
            # Stride across the file so consecutive slots are far apart, which is the
            # engine's regime (16 experts drawn from a layer, 896 experts apart).
            s = (seed_base + i * 7) % NSLOT
            for _ in range(per):
                if s >= NSLOT:
                    s -= NSLOT
                os.preadv(fd, [bufs[i]], s * SLOT)
                s = (s + 89) % NSLOT
                n += 1
            results[i] = (time.monotonic() - t0, n)

        import threading
        th = [threading.Thread(target=worker, args=(i,)) for i in range(lanes)]
        t0 = time.monotonic()
        for t in th:
            t.start()
        for t in th:
            t.join()
        wall = time.monotonic() - t0
        slots = sum(r[1] for r in results)
        return slots * SLOT / wall / 1e6, wall, slots
    finally:
        os.close(fd)
        for b in bufs:
            b.close()


def main():
    warm_slots = max(64, 512 * 1024 * 1024 // SLOT)
    print("engine geometry: nslot=%d slot_bytes=%d (aligned to %d: %s)"
          % (NSLOT, SLOT, ALIGN, SLOT % ALIGN == 0))
    print("sample size: %d slots = %.2f GB per arm" % (SLOTS_PER_SAMPLE,
                                                       SLOTS_PER_SAMPLE * SLOT / GB))
    print("warm-up, discarded: %d slots = %.2f GB\n" % (warm_slots,
                                                        warm_slots * SLOT / GB))

    arms = [
        ("A  O_DIRECT  1 lane", 1, True),
        ("B  O_DIRECT 16 lanes", 16, True),
        ("C buffered  16 lanes", 16, False),
    ]

    for name, lanes, direct in arms:
        sample(lanes, direct, 0, warm_slots)
    print("warm-up done for all arms\n")

    acc = {n: [] for n, _, _ in arms}
    N = 5
    for k in range(N):
        for name, lanes, direct in arms:                 # interleaved
            mbs, wall, slots = sample(lanes, direct, 101 * (k + 1), SLOTS_PER_SAMPLE)
            acc[name].append(mbs)
        print("  sample %d/%d done" % (k + 1, N))

    print("\n=== results, MB/s, %d samples each, arms interleaved" % N)
    print("   %-22s %8s %8s %8s %8s   %s"
          % ("arm", "median", "min", "max", "IQR/med", "verdict"))
    for name, _, _ in arms:
        v = sorted(acc[name])
        med = st.median(v)
        iqr = (st.quantiles(v, n=4)[2] - st.quantiles(v, n=4)[0]) / med if len(v) > 1 else 0
        verdict = "NOISY, no ratio" if iqr > 0.15 else "usable"
        print("   %-22s %8.0f %8.0f %8.0f %8.3f   %s"
              % (name, med, min(v), max(v), iqr, verdict))

    od = st.median(acc["B  O_DIRECT 16 lanes"])
    bu = st.median(acc["C buffered  16 lanes"])
    one = st.median(acc["A  O_DIRECT  1 lane"])
    print("\n=== the two numbers that decide whether the 2.5x gap is real")
    print("   O_DIRECT 16 lanes : %6.0f MB/s" % od)
    print("   buffered 16 lanes : %6.0f MB/s   (%.2fx the O_DIRECT figure)"
          % (bu, bu / od if od else 0))
    print("   O_DIRECT  1 lane  : %6.0f MB/s   (16-lane/1-lane scaling: %.2fx)"
          % (one, od / one if one else 0))
    print("   engine, 16 lanes  :  410 MB/s   (phase2 i/o, O_DIRECT, same unit)")
    print()
    if od >= 800:
        print("   -> the device sustains %.0f MB/s on the engine's own geometry, so the" % od)
        print("      engine's 410 is a real ~%.1fx inefficiency. Chase the read path." % (od / 410.0))
    else:
        print("   -> the device does NOT sustain the historical figure on the engine's")
        print("      geometry. The 2.5x gap was substantially a buffered-read artifact,")
        print("      and the engine's 410 is close to what this drive actually gives.")
        print("      Today's -25% memory-split result is then the whole story, and")
        print("      BENCH_PROTO section 1's O_DIRECT rule was right all along.")


if __name__ == "__main__":
    main()
