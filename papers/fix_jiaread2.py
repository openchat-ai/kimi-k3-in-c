#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""The three remaining 恰读一次, matched on the substring rather than the whole clause.

The first pass matched whole sentences and three failed, because those sentences had been
rewritten since the patterns were written down -- the patterns were stale, not the intent. Matching
the bare term and replacing it handles all occurrences uniformly, which is also correct here:
wherever the phrase appears, it names the paper's own bound rather than a general fact, so the
longer form belongs there too.
"""
import pathlib, re, sys

P = pathlib.Path("papers/论文-慢层只读一次原则.md")
md = P.read_text(encoding="utf-8")
orig = md

# 每层恰读一次 -> 每层刚好只读一次
# 每个 distinct 项恰读一次 -> 每个 distinct 项刚好只读一次
# distinct 项恰读一次 -> distinct 项刚好只读一次  (catches the remaining shapes)
before = len(re.findall(r"恰读一次", md))
md = re.sub(r"恰读一次", "刚好只读一次", md)

left = md.count("恰读一次")
P.write_text(md, encoding="utf-8")
print("  替换 %d 处（按词面统一替换）" % before)
print("  残留「恰读一次」: %d" % left)
print("  「刚好只读一次」现共 %d 处" % md.count("刚好只读一次"))
print("  篇幅变化 %+d 字符" % (len(md) - len(orig)))
if left:
    sys.exit("★ 仍有残留")
print()
for i, l in enumerate(P.read_text(encoding="utf-8").splitlines(), 1):
    if "刚好只读一次" in l:
        s = l.strip()
        j = s.find("刚好只读一次")
        print("  第%4d行  …%s…" % (i, s[max(0, j - 34):j + 22].replace("\n", " ")))