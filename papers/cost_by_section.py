#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Attribute the page-fee characters to sections using explicit boundaries.

The first version bucketed by "nearest preceding heading", which made 参考文献 swallow
everything after it -- the English abstract block, the author bio and the self-check contact.
That reported the bibliography as 6041 characters when 18 references at ~105 characters each
are closer to 1900. Boundaries are named explicitly here instead.
"""
import re
from docx import Document

doc = Document("papers/提交稿-缓存高命中与词元低输出.docx")
paras = [(p.text or "").strip() for p in doc.paragraphs]

BOUNDS = [
    ("前置：中文题名/摘要/关键词/中图分类号",            None,                                  r"^1\s+引言"),
    ("1 引言",                                  r"^1\s+引言",                 r"^2\s+相关工作"),
    ("2 相关工作",                               r"^2\s+相关工作",              r"^3\s+慢速层"),
    ("3 原则：局部性原理的守恒面",                 r"^3\s+慢速层",               r"^4\s+原则的实证"),
    ("4 实证验证：MoE 推理平台",                  r"^4\s+原则的实证",            r"^5\s+下界的工程用法"),
    ("5 下界的工程用法：预算/验收/排查",            r"^5\s+下界的工程用法",        r"^6\s+结论"),
    ("6 结论",                                   r"^6\s+结论",                 r"^附录"),
    ("附录 A 台账说明与方法细节",                  r"^附录\s*A",                 r"^参考文献"),
    ("参考文献",                                 r"^参考文献",                 r"^英文题名"),
    ("前置：英文题名/Abstract/Keywords",           r"^英文题名",                 r"^作者简介与稿件信息"),
    ("稿件信息（作者简介/CCF/自校负责人）",         r"^作者简介与稿件信息",        r"$^never"),
]

RATE = 0.2                       # 200 元/千字符
def find(pat, start=0):
    if pat is None:
        return 0
    for i in range(start, len(paras)):
        if re.match(pat, paras[i]):
            return i
    return len(paras)

rows, total, cursor = [], 0, 0
for name, a, b in BOUNDS:
    s = find(a, cursor)
    if b is None:                      # last bucket runs to the end
        e = len(paras)
    else:
        e = find(b, s + 1)
    n = sum(len(t) for t in paras[s:e] if t)
    rows.append((name, n, n * RATE))
    total += n
    cursor = e

print(f"  {'节':<38}{'字符':>8}{'费用':>9}")
print("  " + "-" * 57)
for name, n, f in rows:
    print(f"  {name[:36]:<38}{n:>8}{f:>9.0f}")
print("  " + "-" * 57)
print(f"  {'段落文字合计':<38}{total:>8}{total*RATE:>9.0f}")

TBL = 1172                        # figure+table area conversion, measured earlier
print(f"  {'图/表折算（含排版空白）':<38}{TBL:>8}{TBL*RATE:>9.0f}")
print()
print(f"  版面设计服务费 估 {(total + TBL) * RATE:.0f} 元")
print(f"  审理费（初审通过后收）300 元")
print()
print("  参考文献实际核对：")
refs = [t for t in paras if re.match(r"^\[\d+\]", t)]
print(f"    {len(refs)} 条，平均 {sum(len(r) for r in refs)/len(refs):.0f} 字符，"
      f"合计 {sum(len(r) for r in refs)} 字符 ≈ {sum(len(r) for r in refs)*RATE:.0f} 元")