#!/usr/bin/env python3
# Feed v61's completed run through the corrected verdict logic, offline. The run is spent, but
# the data exists, and a verdict function that has never been executed on a real void run is
# exactly the kind of thing that turns out to be wrong when it matters.
import statistics, sys, pathlib
p = pathlib.Path("reports/gateab_ab/v61_burst/raw.tsv")
if not p.exists():
    print("no raw.tsv"); sys.exit(1)
d = {}
for line in p.read_text().splitlines():
    f = line.split("\t")
    if len(f) < 7:
        continue
    tag, spt, agg, g0, g1, slp, con = f[:7]
    pair = tag.rsplit("_p", 1)[-1]
    d.setdefault(pair, {})["burst" if tag.startswith("burst") else "noburst"] = \
        dict(spt=float(spt), agg=float(agg), g1=float(g1))
pairs = sorted(k for k in d if len(d[k]) == 2)
print(f"  complete pairs: {len(pairs)}")

da = [100*(d[p]['burst']['agg']-d[p]['noburst']['agg'])/d[p]['noburst']['agg'] for p in pairs]
ds = [100*(d[p]['burst']['spt']-d[p]['noburst']['spt'])/d[p]['noburst']['spt'] for p in pairs]
dg = [100*(d[p]['burst']['g1']-d[p]['noburst']['g1'])/d[p]['noburst']['g1'] for p in pairs]
print(f"  {'pair':<5}{'agg nob':>9}{'agg burst':>11}{'d agg %':>9}"
      f"{'s/tok nob':>11}{'s/tok burst':>13}{'d s/tok %':>11}{'d g1 %':>9}")
for p_ in pairs:
    a, b = d[p_]["noburst"], d[p_]["burst"]
    print(f"  {p_:<5}{a['agg']:>9.0f}{b['agg']:>11.0f}{100*(b['agg']-a['agg'])/a['agg']:>8.1f}%"
          f"{a['spt']:>11.2f}{b['spt']:>13.2f}{100*(b['spt']-a['spt'])/a['spt']:>10.1f}%"
          f"{100*(b['g1']-a['g1'])/a['g1']:>8.1f}%")

def spread(v):
    m = statistics.median(v)
    return (max(v) - min(v)) / abs(m) * 100 if m else float('inf')
sa = [d[p]['noburst']['agg'] for p in pairs]
sb = [d[p]['burst']['agg'] for p in pairs]
print()
print(f"  within-binary spread, aggregate:")
print(f"    noburst {min(sa):.0f}-{max(sa):.0f}  spread {spread(sa):.0f}%")
print(f"    burst   {min(sb):.0f}-{max(sb):.0f}  spread {spread(sb):.0f}%")
pa = spread(da)
print(f"  paired-difference spread: {pa:.0f}% of its own median")
print(f"    per-pair: {[f'{x:+.1f}' for x in da]}")
print(f"    s/token : {[f'{x:+.1f}' for x in ds]}")
print(f"    group1  : {[f'{x:+.1f}' for x in dg]}")

signs = {1 if x > 0 else (-1 if x < 0 else 0) for x in da}
flipped = len(signs) > 1
print()
if flipped or pa >= 100:
    print("  VERDICT: CANNOT MEASURE")
    print("    paired differences change sign, or their spread is at least as large as their")
    print("    median. The effect is NOT confirmed absent -- this run is void and nothing may")
    print("    be decided from it. See BENCH_PROTO 14.1.")
    print("    To resolve it: a genuinely idle window (all three loadavg readings below 1),")
    print("    more pairs, or both arms run concurrently so a pair is shorter than the drift.")
elif statistics.median(da) >= 10:
    print(f"  VERDICT: KEEP -- median paired aggregate difference {statistics.median(da):+.1f}%")
else:
    print(f"  VERDICT: REVERT -- median paired aggregate difference {statistics.median(da):+.1f}%")