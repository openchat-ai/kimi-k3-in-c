#!/usr/bin/env python3
# The bisect returned a monotonic-looking degradation, but its first point -- my own commit,
# 008449c, the same source ab56 ran -- came out at 83.60 s/token where ab56 got 65.21. Either
# the 10-01 commits regressed the engine by 18 s, or this workload is far noisier than the
# 11.6% band the protocol claims. Those have very different consequences, so settle it by
# pooling every 32/15/no-prefetch 3-token run and looking at the spread within one source tree
# as hard as across trees.
import re, pathlib, statistics
root = pathlib.Path("reports/gateab_ab")
rows = []
for f in root.rglob("ctrl.log"):
    txt = f.read_text(errors="replace")
    m = re.search(r"(\d+) tokens in ([\d.]+) s, ([\d.]+) s/token average", txt)
    if not m:
        continue
    ntok, wall, spt = int(m.group(1)), float(m.group(2)), float(m.group(3))
    if ntok != 3:                      # 1-token runs are cold-start dominated
        continue
    if "pf1" in str(f) or "prefetch" in str(f):   # exclude prefetch arms
        continue
    agg = re.search(r"aggregate (\d+) MB/s", txt)
    g0 = re.search(r"group0: \d+ reqs, ([\d.]+) GB \| per-stream (\d+) MB/s", txt)
    g1 = re.search(r"group1: \d+ reqs, ([\d.]+) GB \| per-stream (\d+) MB/s", txt)
    rows.append((spt, int(agg.group(1)) if agg else None,
                 int(g0.group(2)) if g0 else None,
                 int(g1.group(2)) if g1 else None,
                 str(f).replace("reports/gateab_ab/", "")))

rows.sort()
print(f"  all 3-token, no-prefetch runs: n={len(rows)}")
if rows:
    v = [r[0] for r in rows]
    print(f"  min {min(v):.2f}  median {statistics.median(v):.2f}  max {max(v):.2f}"
          f"   spread {100*(max(v)-min(v))/statistics.median(v):.1f}% of median")
print()
print(f"  {'s/tok':>7}  {'agg':>5}  {'g0':>5}  {'g1':>4}  source")
for spt, agg, g0, g1, p in rows:
    print(f"  {spt:7.2f}  {agg if agg else '-':>5}  {g0 if g0 else '-':>5}  {g1 if g1 else '-':>4}  {p}")

# The decisive comparison: runs whose group counters exist, split by whether they came from the
# 09-30 tree or the 10-01 tree. If the 10-01 commits cost 18 s, these two sets separate.
print()
new = [r for r in rows if "v56_groupcheck" in r[4] or "v58_mix" in r[4] or "v59_bisect" in r[4]]
old = [r for r in rows if r not in new]
for name, s in (("09-30 tree (incl. ab56)", old), ("10-01 tree (v56/v58/v59)", new)):
    if s:
        vv = [x[0] for x in s]
        print(f"  {name:26} n={len(vv):2}  min {min(vv):6.2f}  median {statistics.median(vv):6.2f}"
              f"  max {max(vv):6.2f}")
print()
print("  ab56 alone, one script, three consecutive runs on identical source:")
ab = [r for r in rows if "v56_groupcheck" in r[4]]
if len(ab) > 1:
    vv = [x[0] for x in ab]
    print(f"    {', '.join(f'{x:.2f}' for x in vv)}   spread {100*(max(vv)-min(vv))/min(vv):.1f}%")
