#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""State the conclusion as a claim, and fix a reference to a figure that does not exist.

The author asked what the conclusion actually is, observing that the abstract says the conclusion
holds on the byte account and not on the speed account while nowhere in the paper is that
conclusion stated. It was not: chapter 6 restates the argument in order -- phenomenon, principle,
the serialisation factor, the two criteria, the caveats, the advice -- and never makes a claim a
reader could quote. A conclusion chapter that only recaps is not a conclusion.

So it now opens with the claim, in one sentence, and everything after it supports that sentence:

  On a memory-constrained host, reuse of MoE expert weights did not land in the fastest tier the
  bytes were read from, and the hit rate could not show that. Accepting such a change on hit rate
  is unsound; the acceptance line must be the per-tier byte read falling to its distinct-set
  bound, and it must be accompanied by a second criterion for achievable aggregate bandwidth,
  because cost and byte count are not the same direction.

The caveat paragraph now reads as a qualification of that claim rather than as a separate topic,
which is what it always was.

Separately, chapter 6 cited 图 5, which does not exist -- the draft has three figures, and the
paragraph describing the stream whose bytes are largest being nearly free belongs to 表 7. That is
the second criterion's own table.
"""
import pathlib, sys

P = pathlib.Path("papers/论文-慢层只读一次原则.md")
md = P.read_text(encoding="utf-8")
orig = md

# ---- 1. the figure that does not exist ----
a = "搬运量最大的那一流反而近乎免费，搬运量最小的那一流几乎占满了整轮的墙（图 5）"
b = "搬运量最大的那一流反而近乎免费，搬运量最小的那一流几乎占满了整轮的墙（表 7）"
if a not in md:
    sys.exit("★ 未找到「图 5」")
md = md.replace(a, b, 1)
print("  ✓ 行480 图 5 → 表 7")

# ---- 2. chapter 6 opens with the claim ----
a2 = ("本文从一次反常现象出发：按命中率将缓存优化至满格，端到端吞吐仍未达到应有水平。"
      "围绕该现象，本文给出可逐行回查的字节日志审计与一次真机测量：")
b2 = ("**结论是：在存储受限主机上，MoE 专家权重的复用没有落在它能到达的最快层，"
      "而命中率看不出这件事；按命中率验收这类改动不成立，验收线必须是逐层字节读数回落至其 "
      "distinct 集下界，并须另配一条关于可达聚合带宽的口径，因为代价与字节量不同向。**\n\n"
      "这一结论由以下三步得出。本文从一次反常现象出发：按命中率将缓存优化至满格，"
      "端到端吞吐仍未达到应有水平。围绕该现象，本文给出可逐行回查的字节日志审计与一次真机测量：")
if a2 not in md:
    sys.exit("★ 未找到第 6 章开头")
md = md.replace(a2, b2, 1)
print("  ✓ 第 6 章开头补上结论句")

P.write_text(md, encoding="utf-8")
print("  篇幅变化 %+d 字符" % (len(md) - len(orig)))

md2 = P.read_text(encoding="utf-8")
print()
print("  「图 5」残留: %d %s" % (md2.count("图 5"),
                              "✓" if md2.count("图 5") == 0 else "★"))
for i, l in enumerate(md2.splitlines(), 1):
    if "结论是：" in l:
        print("  行%d  %s…" % (i, l.strip()[:110]))