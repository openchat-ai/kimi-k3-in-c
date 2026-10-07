#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Fix three defects in the Chinese abstract, all of them about vagueness.

The abstract said 某系统 -- "some system". The paper measured one system, named in 4.1 and in
reference [1]. Vagueness here costs the reader: they cannot tell whether the observation is the
paper's own or borrowed from literature, and 某 also reads as a hedge the other claims in the same
abstract do not make. Replaced with the actual subject.

It also said 此处以逐词元字节台账回答此类问题, which is a sentence about what the paper is about
rather than what it found, and it repeated itself -- 现象是... followed by 把专家迁至高速盘后...
followed by 命中只换了介质 as a standalone fragment. Three clauses, one fact.

And it closed with 全部数字只对所测实验成立, which is the limitation 4.4 already states in full.
Saying it twice costs the reader the impression that the results are narrower than they are; the
narrow scope is a feature of a single-machine measurement and belongs in the limitations, not in
the abstract's last breath.

Rewritten: the subject is named, the byte finding is stated once, and the closing sentence says
what the reader can do with the criterion rather than restating that it is limited.
"""
import pathlib, sys

P = pathlib.Path("papers/论文-慢层只读一次原则.md")
md = P.read_text(encoding="utf-8")
orig = md

REPL = [
    # 1. name the subject, drop the self-referential clause, state the byte finding once
    ("某系统缓存命中率已满格（CACHE HIT 100%）而端到端吞吐上不去，"
     "此处以逐词元字节台账回答此类问题。现象是每词元仍从低速盘全量重读专家权重 25.83 GB，"
     "占端到端耗时 94%；把专家迁至高速盘后命中率照样满格，而字节台账显示搬运量仍是 25.83 GB，"
     "一个字节未省。**命中只换了介质**。",
     "实测平台为 Kimi K3（2.8T MoE）：缓存命中率调至满格（CACHE HIT 100%），"
     "端到端吞吐仍达不到应有水平，而每词元从低速盘全量重读专家权重 25.83 GB，"
     "占该阶段端到端耗时的 94%；把专家迁至高速盘后命中率照样满格，"
     "逐词元字节台账显示搬运量仍是 25.83 GB。**命中只换了介质，一个字节未省。**"),
    # 2. close on what the criterion is for, not on the limitation already stated in 4.4
    ("该规程是判据成立的前提，不依赖所用的模型与介质。全部数字只对所测实验成立。**",
     "该规程是判据成立的前提，不依赖所用的模型与介质；全部数字取自上述单一平台的实测，"
     "适用范围与限度见 4.4 节。**"),
]

miss = []
for a, b in REPL:
    if a not in md:
        miss.append(a[:40])
        continue
    md = md.replace(a, b, 1)
    print("  ✓ %s…" % a[:46].replace("\n", " "))

P.write_text(md, encoding="utf-8")
print("  替换 %d/%d 处，篇幅变化 %+d 字符" % (len(REPL) - len(miss), len(REPL),
                                       len(md) - len(orig)))
for m in miss:
    print("  ★ 未匹配：%s" % m)

md2 = P.read_text(encoding="utf-8")
print()
ab = [l for l in md2.splitlines() if "CACHE HIT" in l][0]
for s in ab.replace("**", "").split("。")[:-1]:
    s = s.strip()
    if s:
        print("  ·" + s)
print()
for w in ("某系统", "此类问题", "现象是", "全部数字只对"):
    n = md2.count(w)
    print("  %-8s 残留 %d %s" % (w, n, "✓" if n == 0 else "★"))
if miss:
    sys.exit("★ 有未匹配项")