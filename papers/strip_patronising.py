#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Remove the passages that address the reader as if they might misread the paper.

The complaint that prompted this was fair: "本节不证明原则成立，只演示怎么用它" tells an
expert reader they are not capable of evaluating a proof, which reads as condescension. The same
habit appears in three other places -- declaring what the reader "can and cannot take away",
and insisting twice that the instrumentation rule "does not depend on this paper's model".

All of it is removed. What remains is the same content stated as fact about the work rather than
as guidance to the reader.
"""
import pathlib, sys

P = pathlib.Path("papers/论文-慢层只读一次原则.md")
md = P.read_text(encoding="utf-8")
orig = md

REPL = [
    # 1.2 -- drop the "what you can and cannot take away" framing
    ("先说清读者能拿走什么、拿不走什么。能拿走的是三件可复用的东西，不是一条提速配方：",
     "本文给出三件可复用的东西："),
    ("；一条与负载无关的仪表规程（5.6），因为判据本身以计数器为输入。拿不走的是速度收益。"
     "本文不提供",
     "；一条与负载无关的仪表规程（5.6），因为判据本身以计数器为输入。速度收益不在其中——"
     "本文不提供"),
    # 1.3 contribution 5 -- the defensive "does not depend on..." claim, stated once already in 5.6
    ("**该规程不依赖本文的模型、介质或判据**，适用于任何以派生量验收的 I/O 路径，"
     "是上述判据得以成立的前提而非附属。",
     "该规程与本文的模型无关，是上述判据得以成立的前提。"),
    # 5.6 -- same claim, second occurrence; keep it here where it belongs and drop the repeat
    ("该规程不依赖本文的模型、介质或判据，任何以派生量验收的 I/O 路径都用得上，"
     "成本只是报告中多打印几个已有变量。",
     "该规程与模型无关，成本只是报告中多打印几个已有变量。"),
]

miss = []
for a, b in REPL:
    if a not in md:
        miss.append(a[:34])
        continue
    md = md.replace(a, b)

if miss:
    print("  未匹配：")
    for m in miss:
        print("    %s" % m)
    if len(miss) == len(REPL):
        sys.exit("全部未匹配，中止")

P.write_text(md, encoding="utf-8")

left = [p for p in ("读者能拿走", "拿不走", "只演示", "不证明原则",
                    "任何以派生量验收", "不依赖本文的模型") if p in md]
print("  替换 %d 处" % (len(REPL) - len(miss)))
print("  残留同类表述：%s" % ("无" if not left else "、".join(left)))
print("  篇幅变化 %+d 字符" % (len(md) - len(orig)))