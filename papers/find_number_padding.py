#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""List paragraphs whose numeric description is longer than the point it makes.

The rule: the body states the meaning, not the arithmetic. A paragraph that spends several
clauses restating figures already visible in a table or figure is padding, however accurate.
Scored by numerals per 100 characters, restricted to paragraphs long enough to be candidates.
"""
import re, pathlib

md = pathlib.Path("papers/论文-慢层只读一次原则.md").read_text(encoding="utf-8")
lines = md.splitlines()
body = [l.strip() for l in lines
        if l.strip() and not l.strip().startswith(("|", "```", "#", "![", "图 ", "Fig", "表 "))]

rows = []
for i, l in enumerate(lines, 1):
    t = l.strip()
    if not t or t.startswith(("|", "```", "#", "![", "图 ", "Fig", "表 ")):
        continue
    if len(t) < 70:
        continue
    nums = len(re.findall(r"\d+\.?\d*\s*(?:GB|MB|s|%|×|倍|核)?", t))
    if nums >= 4:
        rows.append((nums / len(t) * 100, nums, len(t), i, t))

rows.sort(reverse=True)
print("  数字密度最高的段落（每百字数字个数）")
print("  " + "-" * 70)
for dens, n, ln, i, t in rows[:12]:
    print("  第%4d行  %5.1f/百字  %2d 个  %3d 字" % (i, dens, n, ln))
    print("     %s" % t[:104])
print()
print("  共 %d 段，每百字含 4 个以上数字" % len(rows))