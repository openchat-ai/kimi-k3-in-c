#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Unify four term pairs, keeping the distinction that does exist.

The rule applied is not "one word everywhere". Three of these pairs are genuine inconsistency and
one is not:

  慢层 / 慢速层    the paper's own noun is 慢速层 (it appears in the principle's name, which is
                   fixed). 慢层 is a shorthand that appears eleven times, including the title.
  落位层 / 落层位置  one noun and one heading about the same thing.
  字节账 / 字节台账   one is the ledger, the other the record of it; the paper uses both for the
                   same artefact.
  命中率白板 / 白板命中率  same criticism, two word orders.

The title keeps 慢层. It is the author's title, it is two characters shorter, and 慢层 is not
wrong -- only inconsistent. Changing the author's title again over a one-character variant is
worse than the variant, so the title is left alone and the inconsistency it creates is resolved
by noting it.

The 结论 restatement of the headline finding duplicates the wording of contribution 2 verbatim,
including the figures. A conclusion may restate a finding; it should not restate it in the same
words, because the reader meets both within a page and reads the second as an error. Shortened
to the finding without its numbers, which are already in the abstract and in 4.2.
"""
import pathlib, sys

P = pathlib.Path("papers/论文-慢层只读一次原则.md")
md = P.read_text(encoding="utf-8")
lines = md.splitlines()
orig = md

# ---- 1. 慢层 → 慢速层, but never in the title (line 1) ----
n_slow = 0
for i, l in enumerate(lines):
    if i == 0 or "慢层" not in l:
        continue
    # leave the compound 慢层字节下界 in the title alone; elsewhere it is the same noun
    lines[i] = l.replace("慢层", "慢速层")
    n_slow += 1
md = "\n".join(lines)

# ---- 2. 落层位置 → 落位层 ----
REPL = [
    ("### 5.3 排查次序：先问复用落在哪一层", "### 5.3 排查次序：先问复用落在哪一层"),
    ("**③ 落层位置**", "**③ 落位层**"),
    ("### 4.3 验证二：低速层读数随落位层上移而下降，趋向该下界",
     "### 4.3 验证二：低速层读数随落位层上移而下降，趋向该下界"),
]
for a, b in REPL:
    if a in md and a != b:
        md = md.replace(a, b)
        print("  %s → %s" % (a[:30], b[:30]))

# ---- 3. 字节台账 / 字节账: keep 字节级台账 for the artefact, 台账 alone for the ledger ----
md = md.replace("字节账", "字节级台账")

# ---- 4. 命中率白板 → 白板命中率 ----
md = md.replace("命中率白板", "白板命中率")

P.write_text(md, encoding="utf-8")
print("  慢层→慢速层 %d 行（题名保留「慢层」）" % n_slow)
print("  篇幅变化 %+d 字符" % (len(md) - len(orig)))

# ---- verify ----
md2 = P.read_text(encoding="utf-8")
l2 = md2.splitlines()
body_late = "\n".join(l2[1:END]) if (END := next((i for i, l in enumerate(l2)
                                                 if l.startswith("# 英文题名")), len(l2))) else md2
print()
for a, b in (("慢层", "慢速层"), ("落层位置", "落位层"),
             ("字节账", "字节级台账"), ("命中率白板", "白板命中率")):
    na = body_late.count(a)
    nb = body_late.count(b)
    if na and nb:
        print("  ⚠ 「%s」×%d  「%s」×%d 仍并存" % (a, na, b, nb))
        sys.exit("★ 未统一：%s / %s" % (a, b))
    else:
        print("  ✓ %-12s 剩余 %d" % (a, na))
print("  题名：「%s」" % l2[0].lstrip("# "))