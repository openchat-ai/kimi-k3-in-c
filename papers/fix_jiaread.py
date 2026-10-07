#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Replace 恰读一次 with wording that names the principle and reads plainly.

恰读一次 is a compression that costs the reader a step: it reads as a technical term with no
referent, and the reader has to infer that it means "read once, no more, no less" and that this
is the paper's own bound rather than a general fact about storage. Spelling it as 符合本文原则，
刚好只读一次 ties the phrase to where it comes from and drops the neologism.

Applied to all seven occurrences. Where the surrounding sentence already attributes the bound to
the paper, the shorter form 刚好只读一次 is used instead, to avoid saying 本文 twice in one
sentence.
"""
import pathlib, re, sys

P = pathlib.Path("papers/论文-慢层只读一次原则.md")
md = P.read_text(encoding="utf-8")
orig = md

# (old, new) in document order, so each is matched against text as it stands at that point
REPL = [
    ("且该下界同时可达：存在读取调度使 R_i = 1 对所有 i < k 同时成立",
     "且该下界同时可达：符合本文原则时，存在一种读取调度使 R_i = 1 对所有 i < k 同时成立"),
    ("各低速层读取次数总和的最小值即“各低速层恰读一次”",
     "各低速层读取次数总和的最小值即“符合本文原则、刚好只读一次”"),
    ("推论的下界 1 是“一次生成调用之内，每个 distinct 项恰读一次”",
     "推论的下界 1 是“一次生成调用之内，每个 distinct 项刚好只读一次”"),
    ("向下界（一次生成调用之内，每个 distinct 项恰读一次）单向趋近",
     "向下界（一次生成调用之内，每个 distinct 项刚好只读一次）单向趋近"),
    ("向“一次生成调用内每个 distinct 项恰读一次”收敛",
     "向“一次生成调用内每个 distinct 项刚好只读一次”收敛"),
    ("其中 B_i 的构造即“每个 distinct 项恰读一次”",
     "其中 B_i 的构造即“每个 distinct 项刚好只读一次”"),
    ("本例的下界是一次生成调用之内、distinct 集恰读一次",
     "本例的下界是一次生成调用之内、distinct 集刚好只读一次"),
]

miss = []
for a, b in REPL:
    if a not in md:
        miss.append(a[:36])
        continue
    md = md.replace(a, b)

left = len(re.findall(r"恰读一次", md))
P.write_text(md, encoding="utf-8")

print("  替换 %d 处" % (len(REPL) - len(miss)))
for m in miss:
    print("  未匹配: %s" % m)
print("  残留「恰读一次」: %d" % left)
print("  出现「刚好只读一次」%d 处" % len(re.findall(r"刚好只读一次", md)))
print("  篇幅变化 %+d 字符" % (len(md) - len(orig)))
if left:
    sys.exit("★ 仍有残留，人工核对")