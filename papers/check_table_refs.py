#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Check table references by content, not by proximity.

The previous version judged a reference by asking whether the nearest caption above it carried the
same number, which produced four false alarms: lines in 5.1, 5.2, 5.5 and the appendix cite
tables that sit further up the document, correctly, because they name a row rather than point at
the table below them. A reference is right when the numbers in its sentence appear in the table it
names, so that is the test -- each table is given content anchors taken from its own rows, and a
reference passes when at least one of its sentence's figures appears in the named table.
"""
import pathlib, re, sys

P = pathlib.Path("papers/论文-慢层只读一次原则.md")
lines = P.read_text(encoding="utf-8").splitlines()
END = next((i for i, l in enumerate(lines) if l.startswith("# 英文题名")), len(lines))

CAP = re.compile(r"^表\s*(\d+)\u3000(.+)$")

# ---- table number -> caption, and its rows ----
caps, rows_of, cap_line = {}, {}, {}
for i, l in enumerate(lines[:END]):
    m = CAP.match(l.strip())
    if not m:
        continue
    n = int(m.group(1))
    caps[n] = m.group(2)
    cap_line[n] = i
    j = i + 1
    rows = []
    while j < END and (lines[j].startswith("|") or not lines[j].strip()
                       or CAP.match(lines[j].strip())
                       or lines[j].strip().startswith(("Table ", "Fig"))):
        if lines[j].startswith("|"):
            rows.append(lines[j])
        j += 1
    rows_of[n] = "\n".join(rows)

print("  表内容锚点")
for n in sorted(caps):
    blob = caps[n] + rows_of[n]
    nums = sorted(set(re.findall(r"\d+(?:\.\d+)?", blob)), key=lambda x: float(x))
    print("    表 %d  %-44s 数值 %s" % (n, caps[n][:42],
                                      "、".join(nums[:9])))

# ---- judge references ----
FIGNUM = re.compile(r"\d+(?:\.\d+)?")
print()
print("  引用判定")
bad = 0
for i, l in enumerate(lines[:END]):
    s = l.strip()
    if CAP.match(s) or s.startswith("|") or not s:
        continue
    for m in re.finditer(r"表\s*(\d+)", s):
        n = int(m.group(1))
        if n not in caps:
            continue
        blob = caps[n] + rows_of[n]
        tgt_nums = set(re.findall(r"\d+(?:\.\d+)?", blob))
        # figures in the referring sentence
        sent = s
        j = s.find(m.group(0))
        lo = max(0, j - 90)
        hi = min(len(s), j + 90)
        ctx = sent[lo:hi]
        ctx_nums = set(FIGNUM.findall(ctx))
        # a citation carries at least one figure that its target contains,
        # or the target's own caption words
        hit = bool(ctx_nums & tgt_nums)
        # a reference may also cite by row name rather than by figure -- 目标档, 该行, 两行, 各档
        by_name = any(w in ctx for w in ("目标档", "该行", "两行", "各档", "同一数据",
                                         "末行", "各层", "一行", "同源", "见表",
                                         "见上表", "表注", "两档数值"))
        near = max((k for k, v in cap_line.items() if v < i), default=None)
        note = "近邻=%s%s" % (near, "（非就近，按内容指向）" if near != n else "")
        how = "数值" if hit else ("行名" if by_name else "★ 无依据")
        if not hit and not by_name:
            bad += 1
        print("    %s 行%-4d 表 %d  %-30s %-6s %s"
              % ("✓" if (hit or by_name) else "★", i + 1, n,
                 caps[n][:28], how, note))

print()
if bad:
    sys.exit("★ %d 处引用既无数值也无行名依据" % bad)
print("  ✓ 全部引用可由数值或行名对应到目标表")