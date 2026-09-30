#!/usr/bin/env python3
"""v50: does --prefetch-depth 1 close the gap, or make it worse?

Every engine measurement today ran at prefetch_depth = 0, where k3_run.c:734 never calls
k3_cache_prefetch_ahead, so the prefetch thread is never created, c->pref_started stays 0,
and cache_getmany_inner takes its unlocked path. The engine's normal configuration has the
prefetcher, and with it locked = 1 in phase 1 and a second thread on the same drive. So the
5.3x gap was measured against a degraded path, and this is the first test that touches it.

Both arms are the engine, same 32/15 config, same session, alternating. The device is not
involved, so nothing here depends on a probe.
"""
import glob
import os
import re
import statistics as st

rows = []
for d in sorted(glob.glob("reports/gateab_ab/v50_prefetch/pf*_*")):
    lg = os.path.join(d, "ctrl.log")
    if not os.path.exists(lg):
        continue
    t = open(lg, errors="replace").read()

    def g(pat, cast=float, dflt=None):
        m = re.search(pat, t)
        return cast(m.group(1)) if m else dflt

    tag = os.path.basename(d)
    depth = 1 if tag.startswith("pf1") else 0
    rows.append(dict(
        tag=tag, depth=depth,
        spt=g(r"([0-9.]+) s/token average"),
        hit=g(r"hit I/O   : [0-9.]+ GB in [0-9.]+ s \(wall\) = ([0-9.]+) MB/s"),
        disk=g(r"read from disk: [0-9.]+ GB in [0-9.]+ s \(([0-9.]+) MB/s"),
        perthread=g(r"([0-9.]+) MB/s per-thread"),
        issued=g(r"prefetch      : issued (\d+)", int, 0),
        surv=g(r"survival ([0-9.]+)%"),
        true_hit=g(r"TRUE resident hit rate ([0-9.]+)%"),
        async_on=bool(re.search(r"async expert prefetch: lookahead depth", t)),
        reader=len(re.findall(r"\[reader\]", t)),
    ))

if not rows:
    raise SystemExit("no logs parsed")

print("=== v50, paired A/B, 32 GB / 15 GB, same session, 3 tokens each\n")
print("   %-16s %4s %8s %8s %8s %7s %7s %7s %8s"
      % ("run", "d", "s/tok", "hit MB/s", "per-thr", "issued", "surv%", "true%", "reader"))
for r in sorted(rows, key=lambda x: (x["depth"], x["tag"])):
    print("   %-16s %4d %8s %8.0f %8.0f %7d %7s %7s %8d"
          % (r["tag"], r["depth"], "%.2f" % r["spt"] if r["spt"] else "-",
             r["hit"] or 0, r["perthread"] or 0, r["issued"],
             "%.1f" % r["surv"] if r["surv"] is not None else "-",
             "%.1f" % r["true_hit"] if r["true_hit"] is not None else "-",
             r["reader"]))

print()
for depth in (0, 1):
    v = [r for r in rows if r["depth"] == depth and r["hit"]]
    if not v:
        continue
    hits = [x["hit"] for x in v]
    spts = [x["spt"] for x in v if x["spt"]]
    print("   depth %d : hit I/O %s   median %.0f MB/s"
          % (depth, " ".join("%.0f" % h for h in hits), st.median(hits)))
    if spts:
        print("              s/tok   %s   median %.2f"
              % (" ".join("%.2f" % s for s in spts), st.median(spts)))

a = [r["hit"] for r in rows if r["depth"] == 0 and r["hit"]]
b = [r["hit"] for r in rows if r["depth"] == 1 and r["hit"]]
if a and b:
    print()
    print("   depth 0 median %.0f MB/s   depth 1 median %.0f MB/s   ratio %.2fx"
          % (st.median(a), st.median(b), st.median(b) / st.median(a)))
    print("   engine baseline the whole day rests on: 437 / 437 / 464 MB/s (v49)")
    print("   device, paired with it: 2463 MB/s (5.31x)")

print()
print("=== what the prefetcher actually did")
for r in rows:
    if r["depth"] == 1:
        print("   %-16s async thread %s, issued %d, survival %s%%, TRUE resident %s%%, "
              "[reader] getmany calls %d"
              % (r["tag"], "started" if r["async_on"] else "NOT started", r["issued"],
                 "%.1f" % r["surv"] if r["surv"] is not None else "-",
                 "%.1f" % r["true_hit"] if r["true_hit"] is not None else "-",
                 r["reader"]))
print()
print("   [reader] marks a getmany issued by the prefetch thread rather than the forward")
print("   thread, so a nonzero count means the two-thread overlap the source comment")
print("   describes actually happened in these runs.")
