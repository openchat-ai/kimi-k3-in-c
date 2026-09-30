#!/usr/bin/env python3
"""Are the slow batches a state the machine falls into, or scattered events?

v46 produced 12 slow batches out of 72, and eleven of them sit between 1871 and 1891 MB/s --
a spread of 1% across a 4x gap from the fast batches. That is not a random slowdown, it is a
limit the drive settles at. The question is temporal: do the slow batches cluster in time
(a state entered and left) or are they scattered (independent events)?

If they cluster, then the machine has two modes and a measurement is a coin flip on which one
it landed in. If they scatter, each is its own event and the count matters rather than the
arrangement.
"""
import re
import statistics as st

RUN = "reports/gateab_ab/v46_drift/run.txt"
pat = re.compile(r"^(\d\d:\d\d:\d\d)\s+(\w+)\s+base=\s*(\d+)\s+batch\s+(\d+)/(\d+)\s+(-?\d+)\s+MB/s")

rows = []
for line in open(RUN, errors="replace"):
    m = pat.match(line.strip())
    if m:
        rows.append((m.group(1), m.group(2), int(m.group(3)), int(m.group(4)),
                     float(m.group(6))))

rates = [r[4] for r in rows]
med = st.median(rates)
print("%d batches, median %.0f MB/s\n" % (len(rows), med))

print("=== in order, marking the slow ones")
slows = []
prev = None
for ts, lab, base, b, r in rows:
    flag = "SLOW" if r <= 0.5 * med else "    "
    if r <= 0.5 * med:
        slows.append((ts, lab, base, b, r))
    gap = ""
    if prev:
        gap = "  (+%ds)" % (int(ts[:2]) * 3600 + int(ts[3:5]) * 60 + int(ts[6:8])
                            - (int(prev[:2]) * 3600 + int(prev[3:5]) * 60 + int(prev[6:8])))
    print("   %s %-3s base=%-6d b%d  %6.0f MB/s %s%s"
          % (ts, lab, base, b, r, flag, gap))
    prev = ts

print("\n=== where the slow batches sit, by series and by position within a measurement")
from collections import Counter
print("   by series : %s" % dict(Counter(s[1] for s in slows)))
print("   by batch# : %s   (1-6 within each measurement)"
      % dict(Counter(s[3] for s in slows)))
print("   by base   : %s" % dict(Counter(s[2] for s in slows)))

n_slow_series_T = sum(1 for s in slows if s[1] == "T")
n_slow_series_R = sum(1 for s in slows if s[1] == "R")
print()
print("   series T (fixed base, time only) : %d slow of 36 batches" % n_slow_series_T)
print("   series R (varied base)           : %d slow of 36 batches" % n_slow_series_R)

# Runs of consecutive slow batches = the machine stuck in the slow mode.
run = best = 0
for _, _, _, _, r in rows:
    if r <= 0.5 * med:
        run += 1
        best = max(best, run)
    else:
        run = 0
print("   longest run of consecutive slow batches: %d" % best)

print("\n=== the slow cluster's rate, tightly clustered or a spread?")
sv = [s[4] for s in slows]
core = [v for v in sv if v > 1500]
if core:
    print("   %d of %d slow batches are in 1500-2000 MB/s:" % (len(core), len(sv)))
    print("      min %.0f  max %.0f  spread %.1f%%"
          % (min(core), max(core), (max(core) - min(core)) / st.median(core) * 100))
print()
print("   fast batches: median %.0f  min %.0f" % (st.median(fast), min(fast)) if (fast := [r for r in rates if r > 0.5 * med]) else "")
print("   ratio of modes: %.2fx" % (st.median([r for r in rates if r > 0.5 * med]) / st.median(core) if core else 0))
