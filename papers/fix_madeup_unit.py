#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Replace the invented unit "每会话" with wording a Chinese reader can parse.

"每会话" is a compound I made up. Chinese technical prose does not use it; the reader has to stop
and work out what "会话" quantifies -- the generation call, the model run, the trace window. Five
places did that, and one of them was inside a formula's gloss, where a coined term does the most
damage because it is what the reader will carry away.

Each occurrence is replaced with an explicit phrase naming the object being counted. The point is
not brevity; the point is that the quantity's denominator is stated rather than implied.
"""
import pathlib, sys

P = pathlib.Path("papers/论文-慢层只读一次原则.md")
md = P.read_text(encoding="utf-8")
orig = md

REPL = [
    # 4.2 -- the granularity caveat; name the two things being counted
    ("推论的下界 1 是“每会话、每 distinct 项恰读一次”（见 5.1 预算线）",
     "推论的下界 1 是“一次生成调用之内，每个 distinct 项恰读一次”（见 5.1 预算线）"),
    # 4.3 -- the one-sentence statement of what the corollary predicts
    ("更慢层的读数应随着“复用实际落位层”的上移而向下界（每会话每项恰读一次）单向趋近",
     "更慢层的读数应随着“复用实际落位层”的上移而向下界（一次生成调用之内，每个项恰读一次）单向趋近"),
    # 4.3 -- the reading of the mean/tail columns
    ("高速盘档均值 6.7 GB、稳态尾段约 1.7 GB（后 16 词元）",
     "高速盘档全程均值 6.7 GB、后 16 词元的尾段读数约 1.7 GB"),
    # 5.1 -- the gloss on B_i; this is the one a reader would carry away
    ("B_i = Σ_{d ∈ D_i} slot(d)                 每会话 M_i 的最小读数",
     "B_i = Σ_{d ∈ D_i} slot(d)                 一次生成调用中，介质 M_i 的最小读数"),
    ("B_actual,i / B_i                     超读倍数，1 即已达下界",
     "B_actual,i / B_i                     超读倍数，取值 1 即已达下界"),
    # 5.1 prose
    ("其中 B_i 的构造即“每项恰读一次”。",
     "其中 B_i 的构造即“每个 distinct 项恰读一次”。"),
    # 5.2 -- the KPI, whose denominator also needs naming
    ("本例下界为每会话 distinct 集恰读一次（约 176 GB）",
     "本例的下界是一次生成调用之内、distinct 集恰读一次，合计约 176 GB"),
    ("N 词元会话的 E_1 = 25.83 × N / 176", "该次生成的 E_1 = 25.83 × N / 176"),
    ("由推论 1 对一次会话求和即得每低速层的读数预算",
     "由推论 1 对一次生成调用求和，即得每低速层的读数预算"),
    ("即该次生成共读 B_1 ≈ 25.83 × N GB", "即该次生成共读 B_1 ≈ 25.83 × N GB"),
]

miss = []
for a, b in REPL:
    if a not in md:
        miss.append(a[:40])
        continue
    md = md.replace(a, b)

left = md.count("每会话")
P.write_text(md, encoding="utf-8")

print("  替换 %d 处" % (len(REPL) - len(miss)))
for m in miss:
    print("  未匹配: %s" % m)
print("  残留『每会话』: %d 处" % left)
print("  篇幅变化 %+d 字符" % (len(md) - len(orig)))
if left:
    sys.exit("★ 仍有未替换处，人工核对")