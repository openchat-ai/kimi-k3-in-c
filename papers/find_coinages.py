#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Find every invented compound of the 每-型 and scan for others like it.

"每会话" was a coinage, and once found it prompted a wider question: what else in this paper is
a compound I invented rather than one Chinese technical prose already uses? The test applied is
deliberately mechanical -- a quantifier immediately followed by a two-character noun is
suspicious, because the compounds that are genuinely standard ("每词元") are ones a reader has
seen thousands of times, and the ones that are not are ones they have to decode.

This does not decide; it lists, so the decision is made by reading rather than by counting.
"""
import re, pathlib, collections

md = pathlib.Path("papers/论文-慢层只读一次原则.md").read_text(encoding="utf-8")
lines = md.splitlines()

# ---- 1. quantifier + short noun compounds ----
print("  量化词 + 双字名词（需逐个判断是否为造词）")
comp = collections.Counter()
where = {}
for i, l in enumerate(lines, 1):
    for m in re.finditer(r"(每|单次|一次|多次|逐次|两次|三次)[一-鿿]{2}", l):
        w = m.group(0)
        comp[w] += 1
        where.setdefault(w, []).append(i)
for w, n in comp.most_common():
    flag = "  ← 复核" if w not in ("每词元", "每次") else ""
    print("    %-10s ×%-3d 行 %s%s" % (w, n, where[w][:4], flag))

# ---- 2. other coinage candidates: 量词化名词短语 ----
print()
print("  其他可疑的自造说法")
PAT = [
    (r"[^\w]{0,2}字节账\b", "字节账"),
    (r"落位层", "落位层"),
    (r"字节下界", "字节下界"),
    (r"慢速层", "慢速层"),
    (r"命中满格|满格", "满格"),
    (r"换介质|换了介质", "换介质"),
    (r"双口径", "双口径"),
    (r"白板命中?率?", "白板(命中率)"),
    (r"可回查", "可回查"),
    (r"计一嘴|据实|如实并列", "如实并列"),
    (r"现场|真机体检|一次真机体检", "真机体检"),
]
for pat, name in PAT:
    n = len(re.findall(pat, md))
    if n:
        print("    %-14s ×%d" % (name, n))

# ---- 3. 量 + 短名词（另一种造词法）----
print()
print("  「X量」型")
for m in sorted(set(re.findall(r"[一-鿿]{1,2}量(?![一-鿿])", md))):
    if m not in ("量",):
        print("    %s" % m)