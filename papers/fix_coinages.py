#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Fix the invented compounds the scan surfaced, and record the judgement for the rest.

The coinage list splits three ways:

  fixed    a compound that does not parse without decoding. "三次口径补充" and "三次撤回"
           are revision-book entries wearing prose clothes -- they describe the editor's actions,
           not the science, and they are the same changelog register the user asked to remove.

  kept     compounds that are ordinary in Chinese technical prose and read without decoding:
           每词元, 每槽, 每对, 每条, 单次, 逐次, 字节量, 派生量, 观测量, 落位层, 满格.
           Judged by whether a reader in the field would recognise it, not by frequency.

  renamed two near-misses: "每个项" is a leftover from rewriting 每会话 and says nothing, and
           "真机体检" is cute where the paper means a measurement run.

Absence of frequency is not evidence of coinage -- 每词元 appears 25 times because the workload
is per-token, and it is not invented. The test applied throughout is: can a reader in this field
parse it without stopping?
"""
import pathlib, sys

P = pathlib.Path("papers/论文-慢层只读一次原则.md")
md = P.read_text(encoding="utf-8")
orig = md

REPL = [
    # revision-book register dressed as prose
    ("（第三次口径补充，归因经第四次修正判定）",
     "字节达标之后还需加测串行化，其成因随后经直接测量判定。"),
    ("（第三次撤回）", "该归因经复核排除。"),
    ("（第二次更新）", "该估计的分母不可用。"),
    # leftovers from the 每会话 rewrite that say nothing
    ("向下界（一次生成调用之内，每个项恰读一次）单向趋近",
     "向下界（一次生成调用之内，每个 distinct 项恰读一次）单向趋近"),
    ("每个项恰读一次", "每个 distinct 项恰读一次"),
    # cute where a measurement run is meant
    ("一次真机体检", "一次真机测量"),
    ("可逐行回查的字节日志审计与一次真机体检",
     "可逐行回查的字节日志审计与一次真机测量"),
]

miss = []
for a, b in REPL:
    if a not in md:
        miss.append(a[:38])
        continue
    md = md.replace(a, b)

P.write_text(md, encoding="utf-8")
print("  替换 %d 处" % (len(REPL) - len(miss)))
for m in miss:
    print("  未匹配: %s" % m)
print("  篇幅变化 %+d 字符" % (len(md) - len(orig)))

# verify the changelog register is gone from the revision-book shapes
for w in ("三次口径补充", "第三次撤回", "第二次更新", "真机体检"):
    n = md.count(w)
    print("  残留「%s」%d 处%s" % (w, n, "" if n == 0 else "  ← 需人工核对"))
sys.exit(0)