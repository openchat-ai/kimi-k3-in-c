#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Print each table's content summary, so every reference can be resolved by what it points at.

Resolving 17 references by proximity is not enough: several references name a table further away
than the nearest one, because they point at a table by content rather than by position. This
prints what each table actually contains, and the line each wrong reference sits on with enough
context to judge.
"""
import pathlib, re

P = pathlib.Path("papers/论文-慢层只读一次原则.md")
lines = P.read_text(encoding="utf-8").splitlines()
END = next((i for i, l in enumerate(lines) if l.startswith("# 英文题名")), len(lines))

CAP = re.compile(r"^表\s*(\d+)\u3000(.+)$")

# ---- table contents ----
print("  各表内容（前 3 个数据行）")
i = 0
while i < END:
    m = CAP.match(lines[i].strip())
    if not m:
        i += 1
        continue
    n, cap = m.group(1), m.group(2)
    hdr = lines[i + 2].strip() if i + 2 < END else ""
    rows = []
    j = i + 3
    while j < END and lines[j].startswith("|"):
        rows.append(lines[j].strip())
        j += 1
    print()
    print("    表 %s  %s" % (n, cap[:56]))
    print("      表头 %s" % hdr[:88])
    for r in rows[:3]:
        print("      · %s" % r[:86])
    i = j

# ---- the offending lines, in full ----
print()
print("=" * 74)
print("  引用所在的整行")
BAD = [131, 151, 157, 174, 179, 198, 213, 253, 261, 265, 357, 363, 464, 490]
for ln in BAD:
    s = lines[ln - 1].strip()
    print()
    print("  行%d：" % ln)
    for part in re.split(r"(?<=。)", s):
        if part.strip():
            print("      ·" + part.strip())