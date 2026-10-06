#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Estimate the page-design fee from the actual typeset file.

The journal's FAQ 17: 版面设计服务费 200元/千字符数（计空格数），
图、表、公式折为字符数计算（含排版后产生的空白处）。

So the fee is a function of laid-out area, not of prose alone. Count what is actually in the
docx: characters including spaces, then convert each figure and each table row into the
character-equivalent of the area it occupies.
"""
import re, pathlib
from docx import Document
from docx.shared import Cm

P = pathlib.Path("papers/提交稿-缓存高命中与词元低输出.docx")
doc = Document(P)

# ---- 1. prose: every character in every paragraph, counting spaces ----
prose = 0
for p in doc.paragraphs:
    prose += len(p.text or "")
print(f"  段落文字（含空格）        {prose:>8} 字符")

# ---- 2. what a full page holds, to get the per-character area ----
# 正文双栏，小五(9pt)，A4，页边距上下 1.8cm  → 每栏宽约 8.8cm、栏高约 24cm。
# At 9pt with single spacing a line holds roughly 27 CJK glyphs per 8.8 cm column, and a
# full column about 44 lines. That is a measured-looking assumption; it sets the area-to-
# character conversion, so it is stated rather than hidden.
COL_W_CM, COL_H_CM = 8.8, 24.0
GLYPHS_PER_LINE, LINES_PER_COL = 27, 44
COLUMN_CHARS = GLYPHS_PER_LINE * LINES_PER_COL      # ~1188
FULL_PAGE_CHARS = COLUMN_CHARS * 2
print(f"  单栏字符数（估）          {COLUMN_CHARS:>8} 字符/栏")
print(f"  整页字符数（双栏）        {FULL_PAGE_CHARS:>8} 字符/页")

# ---- 3. figures ----
figs = []
for rel in doc.part.rels.values():
    if "image" in rel.reltype:
        figs.append(rel)
FIG_W_CM = 8.0
fig_chars = 0
for i, rel in enumerate(figs, 1):
    try:
        from PIL import Image
        import io
        im = Image.open(io.BytesIO(rel.target_part.blob))
        h = FIG_W_CM * im.size[1] / im.size[0]
    except Exception:
        h = FIG_W_CM * 0.59              # 1474x868 / 1590x868 both ~0.58 aspect
    area = FIG_W_CM * h
    eq = area / (COL_W_CM * COL_H_CM) * COLUMN_CHARS
    fig_chars += eq
    print(f"  图{i}  {FIG_W_CM}cm × {h:.1f}cm  → 折算 {eq:>6.0f} 字符")
print(f"  插图合计折算              {fig_chars:>8.0f} 字符")

# ---- 4. tables ----
tbl_chars = 0
for ti, t in enumerate(doc.tables, 1):
    rows, cols = len(t.rows), len(t.columns)
    # a table row is ~1.4 line heights in the typeset page; a 4-column row ~ 4*27 glyphs wide
    row_chars = max(COLUMN_CHARS / max(rows, 1), 0)   # its share of the column
    per_row = 1.4 * GLYPHS_PER_LINE * max(cols, 1) / COL_W_CM * (COL_W_CM / 3.0)
    eq = per_row * rows * 0.6                            # 0.6: a table is ~6号字，比正文小
    tbl_chars += eq
    print(f"  表{ti}  {rows}行 × {cols}列  → 折算 {eq:>6.0f} 字符")
print(f"  表格合计折算              {tbl_chars:>8.0f} 字符")

total = prose + fig_chars + tbl_chars
print()
print(f"  合计字符数（估）          {total:>8.0f}")
print()
fee = total / 1000 * 200
print(f"  版面设计服务费            {fee:>8.0f} 元   （200 元/千字符）")
print(f"  审理费（初审通过后收）    {300:>8.0f} 元")
print(f"  首次投入合计              {fee + 300:>8.0f} 元")
print()
print(f"  若为 CCF 会员（8.5 折）   {fee * 0.85:>8.0f} 元   省 {fee * 0.15:>6.0f} 元")
print("  注：8.5 折仅作用于版面设计服务费，审理费 300 元不打折。")
print()
print("  敏感性（版面费随排版空白变化，估±25%）：")
for f in (0.75, 1.0, 1.25):
    v = fee * f
    print(f"    ×{f:<5} {v:>7.0f} 元   折扣省 {v * 0.15:>6.0f} 元")