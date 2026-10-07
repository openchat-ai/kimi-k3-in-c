#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Find table cells long enough to blow the row height.

Column widths now follow content, so a long cell in a narrow column wraps into many lines and
the row grows tall -- the vertical way of overflowing the page, which the width check cannot
see. This reports the cells that wrap more than a couple of lines at 7.5 pt in the width the
builder assigned them.

Rough lines = display width / (column width in half-em per line). A 1.6 cm column at 7.5 pt
fits about 9 CJK glyphs per line.
"""
import sys, pathlib, re
sys.path.insert(0, "papers")
from build_docx import _disp_width

md = pathlib.Path("papers/论文-慢层只读一次原则.md").read_text(encoding="utf-8").splitlines()
tables, cur = [], None
for ln in md:
    s = ln.strip()
    if s.startswith("|"):
        if cur is None:
            cur = []
        cur.append([c.strip() for c in s.strip("|").split("|")])
    elif cur:
        tables.append(cur)
        cur = None
if cur:
    tables.append(cur)

print("  表  列数  单元格显示宽度（半角=1，全角=2），标出 >14 者")
worst = []
for ti, rows in enumerate(tables, 1):
    body = [r for r in rows if not all(set(c) <= set("-: ") for c in r)]
    if not body:
        continue
    cols = len(body[0])
    wid = []
    for ci in range(cols):
        wid.append(max(_disp_width(r[ci]) for r in body))
    print("    表%d  %d 列  宽度 %s" % (ti, cols, " ".join(str(w) for w in wid)))
    for ri, r in enumerate(body):
        for ci, c in enumerate(r):
            if _disp_width(c) > 14:
                print("        行%-2d 列%d  宽%-3d  %r" % (ri, ci, _disp_width(c), c[:40]))
                worst.append((ti, ri, ci, c))

print()
print("  超过 14 半角宽的单元格共 %d 个" % len(worst))
print()
print("  表 单元格里最长的 8 个：")
for ti, ri, ci, c in sorted(worst, key=lambda x: -_disp_width(x[3]))[:8]:
    print("    表%d 行%d 列%d  %r" % (ti, ri, ci, c))