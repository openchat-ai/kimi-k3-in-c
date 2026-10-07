#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Pair every table with its caption, and check the ones that have none.

Guideline item 2 requires a numbered caption and an English translation for every figure and
table. verify_docx.py checks captions it finds but never asks whether a table has one, so an
uncaptioned table passes every check in the suite. This pairs each separator row with the
nearest caption above it and reports the ones that have none.
"""
import pathlib, re, sys

P = pathlib.Path("papers/论文-慢层只读一次原则.md")
lines = P.read_text(encoding="utf-8").splitlines()
END = next((i for i, l in enumerate(lines) if l.startswith("# 英文题名")), len(lines))

CAP = re.compile(r"^(表\s*\d+|Table\s*\d+|图\s*\d+|Fig\.?\s*\d+)")
SEP = re.compile(r"^\|\s*:?-{2,}")

tables = []
for i, l in enumerate(lines[:END]):
    if SEP.match(l):
        tables.append(i)

print("  %-4s %-6s %-8s %s" % ("表", "分隔行", "中文题名", "英文题名"))
print("  " + "-" * 70)
bad = 0
for n, sep in enumerate(tables, 1):
    # A caption may sit above the header row with blank lines between. Search upward past
    # blanks, accept a caption, and stop at the first line that is neither.
    cap_cn = cap_en = None
    j = sep - 2                       # the header row is above the separator
    while j >= 0:
        s = lines[j].strip()
        if not s:
            j -= 1
            continue
        if CAP.match(s):
            if s.startswith("Table") or s.startswith("Fig"):
                cap_en = cap_en or s
            else:
                cap_cn = cap_cn or s
            j -= 1
            continue
        break
    # the English caption may also be below the Chinese one
    j = sep + 1
    while j < len(lines) and j < sep + 4:
        s = lines[j].strip()
        if not s:
            j += 1
            continue
        if re.match(r"^(Table\s*\d+|Fig\.?\s*\d+)", s):
            cap_en = cap_en or s
            break
        break
    ok = bool(cap_cn and cap_en)
    if not ok:
        bad += 1
    print("  %-4d %-6d %-8s %s" % (
        n, sep + 1,
        "✓" if cap_cn else "★ 无",
        (cap_cn[:34] + "…") if cap_cn else "—"))
    print("       %-6s %s" % ("", (cap_en[:60] + "…") if cap_en else "★ 缺英文题名"))

print("  " + "-" * 70)
print("  共 %d 张表，题名不全 %d 张" % (len(tables), bad))

# figure captions
figs = [(i + 1, l.strip()) for i, l in enumerate(lines[:END])
        if re.match(r"^!\[[^\]]*\]\(", l)]
print()
print("  图 %d 张" % len(figs))
for k, s in figs:
    print("    行%-4d %s" % (k, s[:70]))
if bad:
    sys.exit("★ %d 张表题名不全" % bad)