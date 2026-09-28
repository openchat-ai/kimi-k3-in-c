#!/usr/bin/env python3
"""Storage read benchmark, protocol v1 (reports/gateab_ab/BENCH_PROTO.md).

Why this exists: the 2026-09-28 dd-based numbers were invalid three ways over -- single
sampling, no dispersion reported, and buffered reads where the engine uses O_DIRECT
(k3_l2cache.c:74 fdh). This fixes all three.

Protocol:
  * O_DIRECT, same read unit as the engine (17.56 MB slot), same file as the engine
    (experts.l2), separate processes as the concurrency unit (the engine uses one OMP
    thread per outstanding read).
  * per arm: >=512 MB warm-up discarded, then >=5 samples of >=2 GB each
  * arms are interleaved A B C D A B C D, not A A A A B B B B, so monotone drift
    (warm-up, SLC exhaustion, thermal) averages across arms
  * report median, IQR, min..max, and IQR/median; an arm with IQR/median > 0.15 is
    marked NOISY and its value may not carry a ratio claim
  * every raw sample goes to JSON

Usage: bench.py --path /mnt/nvme/experts.l2 --arms consecutive,spread --lanes 1,16
"""
import argparse, json, mmap, os, random, statistics, subprocess, sys, time

SLOT = 17_600_000          # engine slot size (l2_slot = slot_bytes - 2*K3_ST_ALIGN)
ALIGN = 4096               # O_DIRECT alignment for offset, length and buffer
NSLOT = 14_545             # whole experts.l2 in slots (256e9 / 17.6e6)


def one_read(path, offset, nbytes):
    """One O_DIRECT pread. Returns elapsed seconds. Buffer is page-aligned."""
    buf = mmap.mmap(-1, nbytes)            # anonymous, page aligned -> O_DIRECT safe
    try:
        fd = os.open(path, os.O_RDONLY | os.O_DIRECT)
        try:
            t0 = time.monotonic()
            got = os.preadv(fd, [buf], offset)
            dt = time.monotonic() - t0
            if got != nbytes:
                raise IOError("short read %d/%d at %d" % (got, nbytes, offset))
            return dt
        finally:
            os.close(fd)
    finally:
        buf.close()


def worker(path, offsets, nbytes, out_q, idx):
    """One lane: read its offsets back to back, then report its OWN elapsed seconds.

    The lane times itself rather than letting the parent time the whole group: forking N
    Python processes costs hundreds of ms, and at ~2 GB per sample that would otherwise
    be half the measurement. The parent takes max(lane seconds) as the sample's elapsed
    time, which is the right model for N concurrent readers (they all run at once).
    """
    t0 = time.monotonic()
    reads = 0
    for off in offsets:
        try:
            one_read(path, off, nbytes)
            reads += 1
        except Exception as e:                                  # noqa: BLE001
            out_q.put((idx, 0.0, 0, str(e)))
            return
    out_q.put((idx, time.monotonic() - t0, reads, None))


def lane_offsets(rng, arm, lanes, total_bytes, nbytes):
    """Distribute >=total_bytes per lane over offsets matching the arm's pattern."""
    per_lane = int(total_bytes) // lanes
    n = max(1, per_lane // nbytes)
    if arm == "consecutive":
        # lanes read interleaved 17.6 MB slots -> one forward sweep, like the trunk
        base = rng.randrange(0, max(1, NSLOT - n * lanes - 1))
        return [[(base + k * lanes + l) * SLOT for k in range(n)] for l in range(lanes)]
    if arm == "spread":
        # each lane takes slots scattered over a whole layer's 896-slot span, like top-16
        base = rng.randrange(0, max(1, NSLOT - 900))
        out = []
        for l in range(lanes):
            out.append([(base + rng.randrange(0, 896)) * SLOT for _ in range(n)])
        return out
    raise ValueError(arm)


def measure_once(path, arm, lanes, total_bytes, seed, mp):
    """One sample: arm x lanes, >=total_bytes read, aggregate MB/s. No warm-up here --
    the caller discards the first pass, so the warm-up is per (arm, lanes) and identical
    for every arm rather than depending on this function's internals.

    Elapsed = max over lanes (they run concurrently), and the byte count is the SUM of
    what the lanes actually reported reading. An earlier version multiplied the lane sum
    by `lanes` again and timed the parent around p.start() -- together those inflated a
    16-lane sample by 16x and added ~0.8 s of fork, i.e. it reported 31 GB/s on a
    1.09 GB/s drive."""
    rng = random.Random(seed)
    offs = lane_offsets(rng, arm, lanes, total_bytes, SLOT)
    q = mp.Queue()
    procs = [mp.Process(target=worker, args=(path, offs[l], SLOT, q, l))
             for l in range(lanes)]
    for p in procs:
        p.start()
    results = [q.get() for _ in range(lanes)]
    for p in procs:
        p.join()
    if any(r[2] == 0 for r in results):
        return None, results[0][3]
    elapsed = max(r[1] for r in results)
    reads = sum(r[2] for r in results)
    return reads * SLOT / elapsed / 1e6, None


def stats(samples):
    if not samples:
        return None
    s = sorted(samples)
    n = len(s)
    med = statistics.median(s)
    q1, q3 = statistics.quantiles(s, n=4)[0], statistics.quantiles(s, n=4)[2] if n >= 4 else (s[0], s[-1])
    iqr = q3 - q1
    return {"n": n, "median": round(med, 1), "iqr": round(iqr, 1),
            "min": round(s[0], 1), "max": round(s[-1], 1),
            "iqr_over_median": round(iqr / med, 3) if med else None,
            "noisy": (iqr / med) > 0.15 if med else None,
            "samples": [round(x, 1) for x in s]}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--path", required=True)
    ap.add_argument("--arms", default="consecutive,spread")
    ap.add_argument("--lanes", default="1,4,16")
    ap.add_argument("--total-gb", type=float, default=2.0, help="per sample, all lanes together")
    ap.add_argument("--reps", type=int, default=5)
    ap.add_argument("--warm-gb", type=float, default=0.5)
    ap.add_argument("--seed", type=int, default=20260928)
    ap.add_argument("--out", default="-")
    a = ap.parse_args()

    import multiprocessing as mp_
    mp = mp_.get_context("fork")

    arms = a.arms.split(",")
    lanes = [int(x) for x in a.lanes.split(",")]
    combos = [(arm, L) for arm in arms for L in lanes]
    passes = a.reps + 1                              # pass 0 is the warm-up, discarded
    per_combo = {}

    print("== interleaved: one (arm,lanes) per pass, pass 0 discarded as warm-up ==")
    for rnd in range(passes):
        warm = (a.warm_gb * 1e9) if rnd == 0 else a.total_gb * 1e9
        for (arm, L) in combos:
            mbps, err = measure_once(a.path, arm, L, warm, a.seed + rnd, mp)
            if err:
                print("  %-12s L=%-3d ERROR %s" % (arm, L, err))
                continue
            if rnd == 0:
                print("  warm-up  %-12s L=%-3d  %8.1f MB/s (discarded)" % (arm, L, mbps))
            else:
                per_combo.setdefault((arm, L), []).append(mbps)
                print("  pass %-4d %-12s L=%-3d  %8.1f MB/s" % (rnd, arm, L, mbps))

    print()
    print("%-12s %5s %9s %8s %14s %10s  %s" % ("arm", "lanes", "median", "iqr", "min..max", "iqr/med", "verdict"))
    out = {"path": a.path, "protocol": "v1", "unit_bytes": SLOT, "alignment": ALIGN,
           "total_gb_per_sample": a.total_gb, "seed": a.seed, "arms": {}}
    for (arm, L), s in per_combo.items():
        st = stats(s)
        if not st:
            continue
        verdict = "NOISY (>0.15), ratio claims not allowed" if st["noisy"] else "usable"
        print("%-12s %5d %9.1f %8.1f %6.0f..%-6.0f %10.3f  %s"
              % (arm, L, st["median"], st["iqr"], st["min"], st["max"], st["iqr_over_median"], verdict))
        out["arms"]["%s/L%d" % (arm, L)] = st

    if a.out == "-":
        print()
        print(json.dumps(out, indent=2)[:2000])
    else:
        with open(a.out, "w") as f:
            json.dump(out, f, indent=2)
        print()
        print("wrote", a.out)


if __name__ == "__main__":
    main()
