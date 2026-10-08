#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Repoint the 16 wrong table references, each resolved by what the table actually contains.

The renumbering pass remapped in-text references through a map built from caption numbers that
were duplicated at the time -- 表 1 and 表 4 each appeared twice once the new captions went in --
so the map was wrong and the references were rewritten to the wrong tables while the captions
themselves came out correct. Reading the DOCX is what exposed it: figure 2's caption says "same
data as Table 2", and Table 2 is the derived-quantities table, not the one figure 2 plots.

Each replacement below is anchored to a full line and a specific occurrence on it, never to the
bare number, because the same wrong number appears on some lines meaning a different table and
because 表 7 is already correct on line 320 and must not be touched again. The intended target is
recorded with what the table holds, so the mapping can be checked rather than trusted:

  表 1 -> 表 3   the expert-stage baseline ledger: 92x16x17.55 MB = 25.83 GB, 94% of end-to-end
  表 2 -> 表 4   bytes per tier as the landing tier rises, with the unobserved target row
  表 6 -> 表 5   the phase-resolved table: 379 MB/s for the expert stream, 41.8 GB for the backbone
  表 8 -> 表 7   the formula-vs-measured table, which holds the 890/379 MB/s row and the 1.00 ratio

Line 490's 表 7 is already right and is listed as a no-op to prove it was considered.
"""
import pathlib, sys

P = pathlib.Path("papers/论文-慢层只读一次原则.md")
lines = P.read_text(encoding="utf-8").splitlines()

# (1-based line, exact substring on it, replacement)
FIX = [
    (131, "表 1 给出关键数字", "表 3 给出关键数字"),
    (151, "即表 1、表 2 的同一字节量", "即表 3、表 4 的同一字节量"),
    (151, "一列对应表 6 的 41.8", "一列对应表 5 的 41.8"),
    (157, "未直接观测的目标档（表 2）", "未直接观测的目标档（表 4）"),
    (174, "（表 2 的同一数据）", "（表 4 的同一数据）"),
    (179, "与表 2 末行的标注一致", "与表 4 末行的标注一致"),
    (198, "（阶段 A，表 1）", "（阶段 A，表 3）"),
    (198, '表 2 的"目标档"未被到达', '表 4 的"目标档"未被到达'),
    (213, "表 2“目标档”明确标注", "表 4“目标档”明确标注"),
    (253, "与表 1 专家段占端到端 94%", "与表 3 专家段占端到端 94%"),
    (261, "而表 8 该行的 890/379", "而表 7 该行的 890/379"),
    (265, "**表 8 需要两步读法", "**表 7 需要两步读法"),
    (357, "表 6 的两行给出对照", "表 5 的两行给出对照"),
    (363, "（表 6，n=3 中位数）", "（表 5，n=3 中位数）"),
    (464, "4.3 表 2 的“目标档”", "4.3 表 4 的“目标档”"),
    (490, "表 7 的比值在单流顺序档", "表 7 的比值在单流顺序档"),   # already correct
]

fail = []
for ln, old, new in FIX:
    s = lines[ln - 1]
    if old not in s:
        fail.append("行%d 未找到「%s」" % (ln, old))
        continue
    if old == new:
        print("  =  行%-4d 已正确：%s" % (ln, old))
        continue
    lines[ln - 1] = s.replace(old, new, 1)
    print("  ✓  行%-4d %s" % (ln, new))

if fail:
    for f in fail:
        print("  ★  %s" % f)
    sys.exit("★ 有替换未命中，未写入")

P.write_text("\n".join(lines) + "\n", encoding="utf-8")
print("  已写入")