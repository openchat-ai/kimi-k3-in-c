#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Name the model properly wherever the paper currently says only 2.8T.

The draft identifies the test subject by parameter count in four places -- the introduction, the
contributions, 4.1, and the conclusion -- and by "2.8T MoE" in the English abstract. A parameter
count plus an architecture is not an identification: the reader cannot tell which model was
measured, and cannot tell whether 2.8T is the total or the active parameter count, which is the
distinction that decides whether the byte figures are surprising. Reference [1] already gives the
name, so the fix is to use it.

Kimi K3 is written with a space, matching reference [1] and the engine repository name.
"""
import pathlib, sys

P = pathlib.Path("papers/论文-慢层只读一次原则.md")
md = P.read_text(encoding="utf-8")
orig = md

REPL = [
    # ---- 1.2 / 1.1 opening of the introduction ----
    ("本文验证场景即 2.8T 参数开源 MoE 模型[1]",
     "本文验证场景即 Moonshot 开源的 Kimi K3 模型[1]"),
    # ---- contribution 2 ----
    ("对存储受限主机上 2.8T MoE 推理的冷启动",
     "对存储受限主机上 Kimi K3（2.8T MoE）推理的冷启动"),
    # ---- 4.1, the formal statement of the subject ----
    ("实验对象为 2.8T 参数混合专家开源模型[1]",
     "实验对象为 Moonshot 开源的 Kimi K3 混合专家模型[1]（2.8T 参数）"),
    # ---- conclusion ----
    ("对存储受限主机上 2.8T MoE 推理冷启动的实测表明",
     "对存储受限主机上 Kimi K3（2.8T MoE）推理冷启动的实测表明"),
    # ---- English abstract ----
    ("a 2.8T-parameter Mixture-of-Experts model",
     "the Kimi K3 Mixture-of-Experts model (2.8T parameters)"),
]
miss = []
for a, b in REPL:
    if a not in md:
        miss.append(a[:40])
        continue
    md = md.replace(a, b)
    print("  ✓ %s…" % a[:44])

P.write_text(md, encoding="utf-8")
print("  替换 %d/%d 处，篇幅变化 %+d 字符" % (len(REPL) - len(miss), len(REPL),
                                       len(md) - len(orig)))
for m in miss:
    print("  ★ 未匹配：%s" % m)

md2 = P.read_text(encoding="utf-8")
print()
print("  「Kimi K3」出现 %d 处" % md2.count("Kimi K3"))
print("  仍无模型名的「2.8T」：")
for i, l in enumerate(md2.splitlines(), 1):
    if "2.8T" in l and "Kimi" not in l:
        print("    ★ 行%d  %s…" % (i, l.strip()[:80]))
if miss:
    sys.exit("★ 有未匹配项")
print()
print("  全部 2.8T 均已带模型名")