#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Scatter every recorded run: s/token against byte count, and mark which differences fall
inside the noise band.

The point is not a trend line. The point is that the byte axis is flat and the time axis is
not, so a reader sees at a glance which quantity can carry a conclusion. BENCH_PROTO section
14.1 says a paired difference below 10% is undecidable; that band is drawn so the reader can
see at a glance which of the recorded comparisons lands inside it.

Everything plotted is read from the run directories. Nothing is typed in by hand.
"""
import re, pathlib, json

ROOT = pathlib.Path("reports/gateab_ab")
SPT = re.compile(r"([\d.]+)\s+s/token average")
KIO = re.compile(r"kio tier0:\s*(\d+)\s+reqs,\s*([\d.]+)\s*GB delivered")
CONC = re.compile(r"concurrency\s*([\d.]+)x")

rows = []
for lg in sorted(ROOT.rglob("ctrl.log")):
    try:
        t = lg.read_text(errors="replace")
    except Exception:
        continue
    m = KIO.search(t)
    s = SPT.search(t)
    if not (m and s):
        continue
    c = CONC.search(t)
    rows.append(dict(run=lg.parent.name,
                     spt=float(s.group(1)),
                     reqs=int(m.group(1)),
                     gb=float(m.group(2)),
                     conc=float(c.group(1)) if c else None))

print("  抽到 %d 次同时有 s/token 与字节量的运行" % len(rows))
if not rows:
    raise SystemExit("没有同时具备两个量的记录")

by = {}
for r in rows:
    by.setdefault((r["reqs"], r["gb"]), []).append(r)

print()
print("  按字节量分组（配置相同的归一组）")
best = None
for k, v in sorted(by.items(), key=lambda x: -len(x[1])):
    vals = sorted(x["spt"] for x in v)
    lo, hi = vals[0], vals[-1]
    span = (hi - lo) / lo * 100 if lo else 0
    print("    %4d reqs / %6.2f GB : %2d 次  %6.2f–%6.2f s/词元  跨度 %5.1f%%"
          % (k[0], k[1], len(v), lo, hi, span))
    if len(v) >= 3 and (best is None or span > best[1]):
        best = (k, span, sorted(v, key=lambda x: x["spt"]))

# Chronological, not sorted by speed. Sorting by s/token and plotting against run index
# manufactures a perfect staircase -- the first version of this figure did exactly that, and the
# rising curve was an artefact of the ordering rather than a measurement. Run directories carry
# timestamps in their names, so chronological order is recoverable.
def when(r):
    m = re.search(r"(\d{8})_(\d{6})", r["run"])
    return m.group(1) + m.group(2) if m else "999999999999"

if best:
    best = (best[0], best[1], sorted(best[2], key=lambda r: (when(r), r["run"])))

if not best:
    raise SystemExit("没有 3 次以上的同配置组")

k, span, grp = best
print()
print("  选中的同配置组：%d reqs / %.2f GB，共 %d 次，跨度 %.1f%%"
      % (k[0], k[1], len(grp), span))
print("  中位数 %.2f，10%% 判定带 = [%.2f, %.2f]"
      % (sorted(x["spt"] for x in grp)[len(grp) // 2],
         sorted(x["spt"] for x in grp)[len(grp) // 2] * 0.9,
         sorted(x["spt"] for x in grp)[len(grp) // 2] * 1.1))

pathlib.Path("papers/scatter_data.json").write_text(json.dumps(
    dict(reqs=k[0], gb=k[1], span=span,
         pts=[dict(run=x["run"], spt=x["spt"], conc=x["conc"]) for x in grp],
         allruns=[dict(run=x["run"], spt=x["spt"], reqs=x["reqs"], gb=x["gb"]) for x in rows]),
    ensure_ascii=False, indent=1), encoding="utf-8")
print("  数据写入 papers/scatter_data.json")