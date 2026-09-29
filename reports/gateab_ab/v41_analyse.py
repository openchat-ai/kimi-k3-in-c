#!/usr/bin/env python3
"""How much of the expert phase is the serial reserve loop, and how much is the device.

v40 measured the drive at 2723 MB/s with the engine's own ~11 outstanding reads, 6.6x the
410 MB/s the engine reaches, and v38 found the engine requesting 529 GB while the drive
moved 265 GB. Half the reads never became physical I/O. cache_getmany_inner's phase 1 --
the serial reserve loop, pick_victim, and the insertion sort, holding c->mu whenever the
prefetcher runs -- had never been instrumented. K3_TRACE covers phase 2 and compute, so its
share of the expert union was unknown. v41 adds a K3_PHASE_WIDEN row per call.

The question is not "is phase 1 nonzero" but "is phase 1 a large share of the wall". If it
is, the engine was not waiting on the drive at all, and the drive's 6.6x headroom is not
puzzling -- it was never being used.
"""
import csv
import glob
import os
import statistics as st

def union(iv):
    if not iv:
        return 0.0
    s = sorted(iv)
    tot, cs, ce = 0.0, s[0][0], s[0][1]
    for a, b in s[1:]:
        if a > ce:
            tot += ce - cs
            cs, ce = a, b
        else:
            ce = max(ce, b)
    return tot + (ce - cs)

def walls(path):
    w = {}
    for line in open(path, errors="replace"):
        p = line.split()
        if len(p) >= 3 and len(p[0]) == 1 and p[0].isdigit() and p[0] in "01234567":
            try:
                w[int(p[0])] = float(p[2])
            except ValueError:
                pass
    return w

dirs = sorted(glob.glob("reports/gateab_ab/v41_phase1/rep*"))
print("=== %d reps\n" % len(dirs))

allrows = []
for d in dirs:
    t = os.path.join(d, "trace.csv")
    if not os.path.exists(t):
        continue
    per = {}
    with open(t, newline="") as fh:
        for r in csv.DictReader(fh):
            per.setdefault(int(r["token"]), {}).setdefault(r["phase"], []).append(
                (float(r["t0"]), float(r["t1"]), int(r["bytes"])))
    W = walls(os.path.join(d, "ctrl.log"))
    allrows.append((os.path.basename(d), per, W))

if not allrows:
    raise SystemExit("no traces")

name, per, W = allrows[0]
print("=== %s   per-token phase unions (steady state = tokens 1..7)" % name)
print("   %-6s %8s %8s %8s %8s %9s %8s" %
      ("token", "phase1", "expert", "compute", "trunk", "union", "wall"))
for t in sorted(per):
    ph = per[t]
    P = union([(a, b) for a, b, _ in ph.get("widen", [])])
    E = union([(a, b) for a, b, _ in ph.get("expert", [])])
    C = union([(a, b) for a, b, _ in ph.get("compute", [])])
    T = union([(a, b) for a, b, _ in ph.get("trunk", [])])
    U = union([(a, b) for v in ph.values() for a, b, _ in v])
    print("   %-6d %8.2f %8.2f %8.2f %8.2f %9.2f %8.2f" % (t, P, E, C, T, U, W.get(t, 0)))

# The answer: phase 1's share, measured three ways so the choice of denominator is visible.
print("\n=== phase 1 (serial reserve + pick_victim + sort) as a share of the wall")
for name, per, W in allrows:
    p1 = e = c = u = w = 0.0
    for t in range(1, 8):
        ph = per.get(t, {})
        P = union([(a, b) for a, b, _ in ph.get("widen", [])])
        E = union([(a, b) for a, b, _ in ph.get("expert", [])])
        C = union([(a, b) for a, b, _ in ph.get("compute", [])])
        U = union([(a, b) for v in ph.values() for a, b, _ in v])
        p1 += P; e += E; c += C; u += U; w += W.get(t, 0.0)
    n = 7
    print("   %-24s phase1 %6.2f s  expert %6.2f  compute %6.2f  union %6.2f  wall %6.2f"
          % (name, p1 / n, e / n, c / n, u / n, w / n))
    print("   %-24s phase1 / wall = %5.1f%%    phase1 / expert-union = %5.1f%%"
          % ("", 100 * p1 / w, 100 * p1 / e if e else 0))

# Per-call cost, and how many calls are even doing work.
print("\n=== phase 1 per call (the WIDEN rows)")
for name, per, W in allrows:
    durs = []
    nzero = 0
    ntot = 0
    for t in range(1, 8):
        for a, b, _ in per.get(t, {}).get("widen", []):
            durs.append(b - a)
            ntot += 1
            if b - a < 1e-9:
                nzero += 1
    if not durs:
        continue
    v = sorted(durs)
    print("   %-24s n=%4d  median %7.3f s  p90 %7.3f  max %7.3f  total %7.2f s"
          % (name, len(v), st.median(v), v[int(0.9 * (len(v) - 1))], max(v), sum(v)))
    print("   %-24s %d/%d calls took effectively zero (layer had nothing to load)"
          % ("", nzero, ntot))

print("\n=== does phase 1 overlap the expert reads, or sit in front of them?")
for name, per, W in allrows[:1]:
    tot_p1 = tot_ex = 0.0
    inter = 0.0
    for t in range(1, 8):
        pv = per.get(t, {}).get("widen", [])
        ev = per.get(t, {}).get("expert", [])
        for a, b, _ in pv:
            tot_p1 += b - a
        for a, b, _ in ev:
            tot_ex += b - a
        for a, b, _ in pv:
            lo, hi = a, b
            for c2, d2, _ in ev:
                o = min(hi, d2) - max(lo, c2)
                if o > 0:
                    inter += o
    print("   phase1 total %6.2f s   expert total %6.2f s   overlap %6.2f s"
          % (tot_p1, tot_ex, inter))
    if tot_p1:
        print("   share of phase 1 that is INSIDE an expert read: %5.1f%%"
              % (100 * inter / tot_p1))
        print("   share of phase 1 that is serial, outside:          %5.1f%%"
              % (100 * (tot_p1 - inter) / tot_p1))

print("\n=== engine vs device at the same concurrency")
print("   engine phase-2 rate, 11-ish outstanding reads :  410 MB/s")
print("   device, cache preconditioned, R=11 (v40)       : 2723 MB/s")
print("   device, continuous 21 GB, cache full (v39)     : 1377 MB/s")
print("   -> the headroom exists under every regime measured. What the engine actually")
print("      spends its 59 s of expert union on is what phase 1 above now measures.")
