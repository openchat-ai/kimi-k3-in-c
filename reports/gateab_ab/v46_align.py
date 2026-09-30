#!/usr/bin/env python3
"""Line up the guest's batch rates with the host's PhysicalDisk counters.

v45's fixed-base series was 6244 / 6945 / 7057 / 7075 / 1580 / 7047 -- five samples inside
1.13x and one at a quarter of that. Bimodal, not a drift. v46 split each measurement into 6
batches so a short collapse is one slow batch rather than a slow sample, and stamped every
line so the host's once-a-second counters can be lined up against it.

The question is what the drive was doing during the slow batches. % Idle Time separates the
two possibilities that matter: if the drive was idle, the guest was not feeding it; if it was
busy, the drive was the one falling over. Queue depth distinguishes a third: a long queue
with high latency is the drive's own problem, a short one means the requests never arrived.

Verdict rules, fixed before looking at the numbers:
  slow batch AND idle high          -> not the disk; something upstream stopped feeding it
  slow batch AND idle low AND qlen>0 -> the drive itself (latency under queueing)
  slow batch AND qlen ~ 0           -> requests were never issued; the fault is in software
  slow batch AND host shows nothing  -> the event is invisible from the host too
"""
import csv
import os
import re
import statistics as st

RUN = "reports/gateab_ab/v46_drift/run.txt"
HOST = "reports/gateab_ab/v46_drift/host.csv"

# --- guest side: HH:MM:SS  label base=NNN batch n/m  RATE MB/s
batches = []
pat = re.compile(r"^(\d\d:\d\d:\d\d)\s+(\w+)\s+base=\s*(\d+)\s+batch\s+(\d+)/(\d+)\s+(-?\d+)\s+MB/s")
for line in open(RUN, errors="replace"):
    m = pat.match(line.strip())
    if m:
        batches.append(dict(t=m.group(1), lab=m.group(2), base=int(m.group(3)),
                            b=int(m.group(4)), rate=float(m.group(6))))
means = {}
for line in open(RUN, errors="replace"):
    m = re.match(r"^\s+(\w+)\s+base=\s*(\d+)\s+MEAN\s+(-?\d+)\s+MB/s", line.rstrip())
    if m:
        means.setdefault(m.group(1) + ":" + m.group(2), []).append(float(m.group(3)))

if not batches:
    raise SystemExit("no batch lines parsed")

rates = [x["rate"] for x in batches]
med = st.median(rates)
print("=== guest side: %d batches, median %.0f MB/s, min %.0f, max %.0f, max/med %.2fx"
      % (len(batches), med, min(rates), max(rates), max(rates) / med))

fast = [r for r in rates if r > 0.5 * med]
slow = [r for r in rates if r <= 0.5 * med]
print("   fast (>50%% of median): %d batches, median %.0f" % (len(fast), st.median(fast)))
print("   slow (<=50%% of median): %d batches, %s"
      % (len(slow), " ".join("%.0f" % r for r in sorted(slow)) if slow else "none"))

# --- host side
host = {}
if os.path.exists(HOST):
    with open(HOST, newline="", errors="replace") as fh:
        rd = csv.DictReader(fh)
        for r in rd:
            try:
                host[r["HH:MM:SS"]] = dict(
                    idle=float(r["idle_pct"]),
                    lat=float(r["avglat_ms"]),
                    q=float(r["qlen"]),
                    mb=float(r["read_MBps"]),
                    ios=float(r["reads_s"]))
            except (ValueError, KeyError):
                continue
print("\n=== host side: %d samples" % len(host))

def near(ts, span=2):
    """Host samples at 1 Hz; take the nearest couple around a guest timestamp."""
    h, m, s = (int(x) for x in ts.split(":"))
    target = h * 3600 + m * 60 + s
    out = []
    for ht, v in host.items():
        hh, mm, ss = (int(x) for x in ht.split(":"))
        d = abs(hh * 3600 + mm * 60 + ss - target)
        if d <= span:
            out.append((d, v))
    out.sort(key=lambda p: p[0])
    return [v for _, v in out]

if not host:
    print("   no host samples -- cannot correlate")
    raise SystemExit(0)

print("\n=== host state, split by whether the guest batch was fast or slow")
for name, sel in (("FAST batches", fast), ("SLOW batches", slow)):
    got = []
    for x in batches:
        if x["rate"] not in sel:
            continue
        got += near(x["t"])
    if not got:
        print("   %-13s (none matched a host sample)" % name)
        continue
    print("   %-13s n=%3d  idle %5.1f%%  latency %6.2f ms  qlen %5.1f  read %6.0f MB/s  ios %5.0f"
          % (name, len(got),
             st.median([g["idle"] for g in got]),
             st.median([g["lat"] for g in got]),
             st.median([g["q"] for g in got]),
             st.median([g["mb"] for g in got]),
             st.median([g["ios"] for g in got])))

print("\n=== every slow batch, with the host at that moment")
for x in sorted(batches, key=lambda y: y["rate"])[:12]:
    n = near(x["t"])
    if not n:
        print("   %s %-3s base=%5d b%d  %6.0f MB/s   (no host sample)"
              % (x["t"], x["lab"], x["base"], x["b"], x["rate"]))
        continue
    g = n[len(n) // 2]
    print("   %s %-3s base=%5d b%d  %6.0f MB/s   idle %5.1f%%  lat %6.2f ms  qlen %4.0f  read %5.0f MB/s"
          % (x["t"], x["lab"], x["base"], x["b"], x["rate"], g["idle"], g["lat"], g["q"], g["mb"]))

print("\n=== region effect (series R, mean per base)")
for k in sorted(means):
    if k.startswith("R:"):
        b = k.split(":")[1]
        print("   base %-6s %s   mean %.0f MB/s  (%.0f GB in)"
              % (b, " ".join("%6.0f" % v for v in means[k]),
                 st.mean(means[k]), int(b) * 17547264 / 1e9))
