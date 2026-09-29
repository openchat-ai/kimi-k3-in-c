#!/usr/bin/env python3
"""Can table 2b be rebuilt, or does it still refuse to reconcile?

The v25 table this replaces summed phase DURATIONS and called the result "exposure on
the wall". Those are different quantities, and the trace shows why: within one token the
phases overlap. From rep1's first layers:

    trunk   221.815257 -> 222.461068
    expert  222.501147 -> 222.699335
    compute 222.461070 -> 222.818280      <- compute overlaps expert by 0.198 s

So a duration sum double-counts every overlap, and the resulting "share of wall" cannot
add to 100%. Exposure on the wall is the UNION of a phase's intervals, not their sum.
That is very likely the whole reason 2.4+49.2+16.8 = 68.4 s exceeded the stated 66.12 s
end-to-end, and why the shares came out 3.6/74.4/25.4% against a stated 4/75/21%.

This computes, per token: the union interval per phase, the union across all phases, and
the wall time the engine itself reported for that token. The table is rebuildable only if
the three phases' unions account for the wall.

t0/t1 are CLOCK_MONOTONIC since boot, not since process start, so everything here is
expressed as a duration and absolute epochs are never compared across runs.
"""
import csv
import glob
import os
import sys

def union(intervals):
    """Total length covered by a set of intervals (merging overlaps)."""
    if not intervals:
        return 0.0
    s = sorted(intervals)
    total, cs, ce = 0.0, s[0][0], s[0][1]
    for a, b in s[1:]:
        if a > ce:
            total += ce - cs
            cs, ce = a, b
        else:
            ce = max(ce, b)
    return total + (ce - cs)

def wall(intervals):
    """(first start, last end) across a set of intervals."""
    if not intervals:
        return 0.0, 0.0
    return min(a for a, _ in intervals), max(b for _, b in intervals)

def load(path):
    per = {}
    with open(path, newline="") as fh:
        for row in csv.DictReader(fh):
            tok = int(row["token"])
            ph = row["phase"]
            per.setdefault(tok, {}).setdefault(ph, []).append(
                (float(row["t0"]), float(row["t1"]), int(row["bytes"])))
    return per

def main():
    dirs = sorted(glob.glob("reports/gateab_ab/v32_table2b/rep*"))
    if not dirs:
        sys.exit("no reps yet")
    d = dirs[0]
    print("=== %s\n" % d)
    per = load(os.path.join(d, "trace.csv"))

    print("=== per-token phase exposure, UNION of intervals (not a duration sum)")
    print("   %-6s %9s %9s %9s %11s %11s" %
          ("token", "trunk", "expert", "compute", "union", "sum-of-dur"))
    rows = []
    for tok in sorted(per):
        u, s = {}, 0.0
        for ph in ("trunk", "expert", "compute"):
            iv = [(a, b) for a, b, _ in per[tok].get(ph, [])]
            u[ph] = union(iv)
            s += sum(b - a for a, b in iv)
        allph = [x for ph in per[tok].values() for x in ph]
        ua = union([(a, b) for a, b, _ in allph])
        rows.append((tok, u, ua, s))
        print("   %-6d %9.2f %9.2f %9.2f %11.2f %11.2f" %
              (tok, u["trunk"], u["expert"], u["compute"], ua, s))

    tt = sum(r[1]["trunk"] for r in rows)
    te = sum(r[1]["expert"] for r in rows)
    tc = sum(r[1]["compute"] for r in rows)
    tu = sum(r[2] for r in rows)
    ts = sum(r[3] for r in rows)
    print("   %-6s %9.2f %9.2f %9.2f %11.2f %11.2f" % ("ALL", tt, te, tc, tu, ts))
    print()
    print("   overlap double-count, i.e. sum-of-durations minus true union: %.2f s"
          % (ts - tu))

    # Bytes, straight from the trace, per token and total.
    print()
    print("=== per-token bytes")
    for tok in sorted(per):
        allph = [x for ph in per[tok].values() for x in ph]
        by_phase = {}
        for ph, iv in per[tok].items():
            by_phase[ph] = sum(n for _, _, n in iv)
        print("   token=%d  total %7.2f GB   (trunk %6.2f / expert %6.2f)" %
              (tok, sum(by_phase.values()) / 1e9,
               by_phase.get("trunk", 0) / 1e9, by_phase.get("expert", 0) / 1e9))

    # Reconcile against the engine's own per-token wall.
    print()
    print("=== reconcile union against the engine's per-token wall")
    walls = {}
    for line in open(os.path.join(d, "ctrl.log"), errors="replace"):
        p = line.split()
        if len(p) >= 3 and p[0].isdigit() and p[0] in "01234567" and len(p[0]) == 1:
            try:
                walls[int(p[0])] = float(p[2])
            except ValueError:
                pass
    if not walls:
        print("   (could not parse per-token wall from ctrl.log)")
        return
    for tok, u, ua, s in rows:
        w = walls.get(tok)
        if w is None:
            continue
        print("   token=%d  union %7.2f s  engine wall %7.2f s  accounted %5.1f%%  "
              "double-count %5.2f s" % (tok, ua, w, ua / w * 100, s - ua))
    tw = sum(walls[t] for t in walls if t in per)
    print("   %-6s union %7.2f s  engine wall %7.2f s  accounted %5.1f%%" %
          ("ALL", tu, tw, tu / tw * 100))

if __name__ == "__main__":
    main()
