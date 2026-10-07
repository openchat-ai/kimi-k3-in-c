#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Give the four uncaptained tables numbers, captions and English translations.

Guideline item 2 requires a numbered caption and an English translation for every table. Four
tables had neither and passed the entire checker suite, because verify_docx.py checks captions it
finds and never asks whether a table has one. They are now numbered in document order, which
renumbers everything after them: the former 表 4 becomes 表 8, and its two in-text references
follow.

The captions are written from what each table holds, not from the paragraph above it, since the
surrounding prose already states what the table is for and repeating it in the caption is the
numbering padding the draft has been trying to avoid.
"""
import pathlib, re, sys

P = pathlib.Path("papers/论文-慢层只读一次原则.md")
md = P.read_text(encoding="utf-8")
orig = md

# ---- 1. renumber the existing captions 4 -> 8, walking backwards ----
for old, new in ((4, 8), (3, 6), (2, 5), (1, 4)):
    for a, b in (("表 %d\u3000" % old, "表 %d\u3000" % new),
                 ("Table %d\u3000" % old, "Table %d\u3000" % new)):
        if a in md:
            md = md.replace(a, b)
            print("  %s → %s" % (a.strip(), b.strip()))

# in-text references to the old numbers
md = md.replace("表 4 的比值", "表 8 的比值")
md = md.replace("表 4 的同一数据", "表 8 的同一数据")
md = md.replace("表 4 各档的字节与带宽出处", "表 8 各档的字节与带宽出处")

# ---- 2. caption the four uncaptained tables, by their header row ----
CAPTIONS = [
    ("| 字段 | 它报出来的 | 独立量报的 | 差 |",
     "表 1\u3000六个曾产生错误结论的计数器字段",
     "Table 1\u3000Six counter fields that produced wrong conclusions"),
    ("| 派生量 | 交叉校验对象 |",
     "表 2\u3000派生量与其交叉校验对象",
     "Table 2\u3000Derived quantities and their cross-check counterparts"),
    ("| L1 策略 | cache | 三轮实测 | 中位 |",
     "表 3\u3000替换策略在字节口径下的复测（GB/词元）",
     "Table 3\u3000Replacement policy re-measured on the byte account (GB/token)"),
    ("| 实际发生的错误 | 观测平面 | 四步能否抓住 | 依据 |",
     "表 4\u3000本轮八处错误的四步排查回放",
     "Table 4\u3000Replay of this run's eight errors against the four-step order"),
]

for header, cn, en in CAPTIONS:
    if header not in md:
        print("  ★ 未找到表头：%s" % header[:30])
        sys.exit(1)
    md = md.replace(header, cn + "\n" + en + "\n\n" + header, 1)
    print("  加题名：%s" % cn)

P.write_text(md, encoding="utf-8")
print("  篇幅变化 %+d 字符" % (len(md) - len(orig)))

# ---- verify ----
md2 = P.read_text(encoding="utf-8")
cn = [int(m) for m in re.findall(r"^表\s*(\d+)\u3000", md2, re.M)]
en = [int(m) for m in re.findall(r"^Table\s*(\d+)\u3000", md2, re.M)]
print()
print("  中文表题 %s" % cn)
print("  英文表题 %s" % en)
print("  连续且一一对应：%s" % (cn == en == list(range(1, len(cn) + 1))))
if cn != en or cn != list(range(1, len(cn) + 1)):
    sys.exit("★ 编号不连续")
print("  共 %d 张表，全部有中英文题名" % len(cn))