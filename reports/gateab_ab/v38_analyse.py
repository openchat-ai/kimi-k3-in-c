#!/usr/bin/env python3
"""What the physical drive was actually doing during a k3 run.

The guest has no PMU (BENCH_PROTO section 12), so yesterday's three probes could not tell
a saturated drive from a starved one, and the 47% swing between v36's 1786 MB/s and v37's
1214 MB/s stayed unexplained. The host sees the drive downstream of the guest's VHDX, so
% Idle Time answers the question directly: was the physical device busy, or was it waiting
for someone.

Also checks the two things the guest cannot self-check: whether the physical read bytes
match what the engine asked for (VHDX amplification or absorption), and what queue depth
the host actually saw, versus the 16 the engine believed it was offering.
"""
import csv
import glob
import os
import statistics as st
import sys

rows = []
with open(sorted(glob.glob("reports/gateab_ab/v38_hostcounters/sample-*.csv"))[-1],
          newline="", encoding="utf-8-sig") as fh:
    for r in csv.DictReader(fh):
        # path looks like \\host\physicaldisk(0 c: d:)\disk read bytes/sec
        path = r["Path"]
        leaf = path.rsplit("\\", 1)[-1].lower()
        try:
            v = float(r["Value"])
        except ValueError:
            continue
        rows.append((r["Time"], r["Tag"], r["Disk"], leaf, v))

tags = sorted({t for _, t, _, _, _ in rows},
              key=lambda t: {"idle_before": 0, "run": 1, "idle_after": 2}.get(t, 9))
disks = sorted({d for _, _, d, _, _ in rows})

def series(tag, disk, leaf):
    return [v for _, t, d, l, v in rows if t == tag and d == disk and l == leaf]

def report(leaf, unit, scale=1.0, agg=st.mean):
    print("\n=== %s (%s)" % (leaf, unit))
    for disk in disks:
        for tag in tags:
            s = series(tag, disk, leaf)
            if not s:
                continue
            vals = [x * scale for x in s]
            print("   %-22s %-12s n=%3d  mean %8.2f  min %8.2f  max %8.2f"
                  % (disk, tag, len(vals), agg(vals), min(vals), max(vals)))

print("=== sampling window")
for tag in tags:
    s = [t for t, tt, _, _, _ in rows if tt == tag]
    if s:
        print("   %-12s %s .. %s  (%d samples)" % (tag, min(s), max(s), len(s)))

report("disk read bytes/sec", "MB/s", 1e-6)
report("% idle time", "%")
report("avg. disk sec/read", "ms", 1000.0)
report("current disk queue length", "requests")
report("disk reads/sec", "reads/s")
report("avg. disk bytes/read", "MB", 1e-6)

# The decisive one: was the physical drive saturated while the engine ran?
print("\n=== was the physical drive saturated during the run?")
for disk in disks:
    idle = [v for _, t, d, l, v in rows
            if t == "run" and d == disk and l == "% idle time"]
    if not idle:
        continue
    busy = [100 - v for v in idle]
    print("   %-22s busy mean %5.1f%%  min %5.1f%%  max %5.1f%%  "
          "samples at >90%% busy: %d/%d"
          % (disk, st.mean(busy), min(busy), max(busy),
             sum(1 for b in busy if b > 90), len(busy)))

# VHDX check: physical read bytes vs the engine's request.
print("\n=== does the guest's byte count match the physical drive's?")
tot_guest = (349030957056 + 180105117696) / 1e9
print("   engine asked for : %.1f GB over 8 tokens (%.1f GB/token)"
      % (tot_guest, tot_guest / 8))
for disk in disks:
    rb = series("run", disk, "disk read bytes/sec")
    if not rb:
        continue
    # the sampler ticks 1/s; integrate to get physical bytes during the run
    phys = sum(rb) / 1e9
    print("   %-22s physical read during run: %7.1f GB  (%.2fx the guest's ask)"
          % (disk, phys, phys / tot_guest if tot_guest else 0))
