#!/usr/bin/env python3
"""How much of the gap is concurrency? The engine issues ~11 reads at a time, and that is
the number no probe has ever used.

Where 11 comes from. The v32 trace shows each layer's expert phase as a single event of
~0.19 GB, which is 11 slots of 17547264 B, and getmany_inner runs that batch on an OMP loop
of 16 threads (k3_cache.c:280). 93 layers run sequentially per token, so the engine keeps
roughly 11 reads outstanding at any moment -- fewer than it has threads. v37 swept burst
granularity but in units of slots PER LANE, so its smallest arm was 3 x 16 = 48 slots
concurrent, more than four times the engine's real figure. v37 therefore did not test the
engine's regime, and the "burst granularity is not the explanation" conclusion was not
supported.

v39 removed the other excuse: with the controller's cache deliberately full, the drive still
sustains 1377 MB/s against the engine's 410, so the gap is not a cache artifact. But the
drive was only ~35% utilised during a real run (v38), and a single layer's expert event took
12.65 s where the drive needs 0.14 s. Both point the same way: the engine is not giving the
device enough to do, so the question is what throughput looks like as a function of how
many reads are outstanding.

Design. R concurrent reads per round, R in {1, 2, 4, 8, 11, 16}, each round timed
separately from the pause, because a fixed pause between rounds otherwise dominates the
clock and the measurement degenerates into counting pauses. A 0.15 s pause between rounds
matches the engine's own per-layer arithmetic (14.85 s of pure compute spread over 93
layers). Two rates are reported and they answer different questions:

  effective  bytes / summed read time only. What the device can do at concurrency R.
  observed   bytes / wall including pauses. What the engine would actually experience.

The device cache is preconditioned first, same as v39, so the comparison is at a controlled
device state rather than whatever the session happened to leave behind.
"""
import mmap
import os
import statistics as st
import sys
import threading
import time

L2 = "/mnt/nvme/experts.l2"
NSLOT = 17096
SLOT = 17547264
ROUNDS = 120
PAUSE = 0.15
PRECOND_GB = 40
PRECOND_PATH = "/mnt/nvme/precond.tmp"
ENGINE = 410.0
ENGINE_R = 11          # the engine's own outstanding-read count
ARMS = [1, 2, 4, 8, 11, 16]


def buf(n):
    return mmap.mmap(-1, n)


def precondition():
    """Same as v39: overwrite the controller cache, leave the filesystem alone."""
    nbytes = int(PRECOND_GB * 1000 ** 3)
    chunk = 32 * 1000 * 1000 * 1000
    t0 = time.monotonic()
    fd = os.open(PRECOND_PATH, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_DIRECT, 0o644)
    try:
        b = buf(chunk)
        pat = bytes(bytearray((i * 7 + 13) & 0xFF for i in range(4096)))
        off = 0
        while off < chunk:
            b[off:off + 4096] = pat
            off += 1000 * 1000
        view = memoryview(b)
        written = 0
        while written < nbytes:
            take = min(len(b), nbytes - written)
            written += os.write(fd, view[:take])
        view.release()
    finally:
        os.close(fd)
    os.sync()
    print("   preconditioned %d GB in %.1f s" % (PRECOND_GB, time.monotonic() - t0),
          flush=True)


def round_once(R, seed):
    """One round of R CONCURRENT reads, timed.

    The threads must actually be concurrent. A plain loop over os.preadv looks
    equivalent and measures single-stream throughput at every R, which would make the whole
    sweep report the same number. The smoke test caught exactly that: R=2 came out at 1.92x
    the wall time of R=1, which is serialisation, not concurrency.
    """
    fd = os.open(L2, os.O_RDONLY | os.O_DIRECT)
    try:
        bufs = [buf(SLOT) for _ in range(R)]
        base = (seed * 131 + 17) % NSLOT
        # Lane i starts far from lane j so concurrent reads do not collide in SLC or in the
        # controller's own queue.
        offs = []
        for i in range(R):
            s = (base + i * 137) % NSLOT
            if s >= NSLOT:
                s -= NSLOT
            offs.append(s * SLOT)

        def lane(i):
            os.preadv(fd, [bufs[i]], offs[i])

        th = [threading.Thread(target=lane, args=(i,)) for i in range(R)]
        t0 = time.monotonic()
        for t in th:
            t.start()
        for t in th:
            t.join()
        el = time.monotonic() - t0
        for b in bufs:
            b.close()
        return el, R * SLOT
    finally:
        os.close(fd)


def arm(R, seed):
    """ROUNDS rounds, each timed on its own so the pause is excluded from the read rate."""
    read_s = 0.0
    nbytes = 0
    for k in range(ROUNDS):
        el, nb = round_once(R, seed + k * 17)
        read_s += el
        nbytes += nb
        if PAUSE:
            time.sleep(PAUSE)
    wall_s = read_s + ROUNDS * PAUSE
    eff = nbytes / read_s / 1e6 if read_s else 0.0
    obs = nbytes / wall_s / 1e6 if wall_s else 0.0
    return eff, obs, nbytes


def main():
    print("engine for comparison: %d MB/s at ~%d outstanding reads"
          % (ENGINE, ENGINE_R))
    print("device cache preconditioned to a known state first (v39 method)\n", flush=True)

    # Sanity: geometry must still be what the engine sees.
    assert SLOT == 17547264 and NSLOT == 17096, "engine geometry changed"

    print("[1/2] preconditioning ...", flush=True)
    precondition()

    print("[2/2] concurrency sweep, %d rounds/arm, %ds pause, n=5 interleaved"
          % (ROUNDS, PAUSE), flush=True)
    acc = {R: {"eff": [], "obs": [], "bytes": []} for R in ARMS}
    for k in range(5):
        for R in ARMS:
            eff, obs, nb = arm(R, seed=1000 * (k + 1) + R)
            acc[R]["eff"].append(eff)
            acc[R]["obs"].append(obs)
            acc[R]["bytes"].append(nb)
        print("      round %d/5 done" % (k + 1), flush=True)

    print("\n=== effective rate: bytes / read time only (pause excluded)")
    print("   %-6s %8s %8s %9s %10s %9s" %
          ("R", "median", "min", "IQR/med", "vs engine", "verdict"))
    for R in ARMS:
        v = sorted(acc[R]["eff"])
        med = st.median(v)
        q = st.quantiles(v, n=4)
        iqr = (q[2] - q[0]) / med
        print("   %-6d %8.0f %8.0f %9.3f %9.2fx %9s" %
              (R, med, min(v), iqr, med / ENGINE, "NOISY" if iqr > 0.15 else "usable"))

    print("\n=== observed rate: includes the 0.15 s pause per layer")
    print("   %-6s %8s %8s %9s" % ("R", "median", "min", "IQR/med"))
    for R in ARMS:
        v = sorted(acc[R]["obs"])
        med = st.median(v)
        q = st.quantiles(v, n=4)
        iqr = (q[2] - q[0]) / med
        print("   %-6d %8.0f %8.0f %9.3f" % (R, med, min(v), iqr))

    print("\n=== bytes actually moved per arm (n=5 totals)")
    for R in ARMS:
        print("   R=%-3d %8.1f GB" % (R, sum(acc[R]["bytes"]) / 1e9))

    med11 = st.median(acc[ENGINE_R]["eff"])
    med16 = st.median(acc[16]["eff"])
    print()
    print("   engine's own R=%d : %.0f MB/s effective" % (ENGINE_R, med11))
    print("   device at R=16    : %.0f MB/s effective" % med16)
    print("   ratio              : %.2fx" % (med16 / med11 if med11 else 0))
    if med11 < ENGINE * 0.6:
        print("   -> at the engine's own concurrency the device cannot even reach the")
        print("      engine's rate, so the gap is not a concurrency-setting error.")
    else:
        print("   -> the device at the engine's concurrency does reach the engine's rate,")
        print("      which would point the remaining gap at R itself: more outstanding")
        print("      reads per layer is a lever.")

    try:
        os.unlink(PRECOND_PATH)
    except OSError:
        pass


if __name__ == "__main__":
    main()
