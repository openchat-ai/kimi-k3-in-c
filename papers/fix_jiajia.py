#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Remove 骨架 from the draft.

The author used 骨架 as a metaphor for the draft's structure when explaining to me what they
meant by the principle's standing. It was never text for the paper. Putting the word in the
abstract and in 1.2 mistook a figure of speech for a statement, and the abstract is the worst
possible place for a metaphor: a reviewer reads it as a claim about the contribution's
structure, which is not what it means.

Replaced with 作用, which is the word the surrounding sentence already argues from -- what the
principle does, rather than what the paper is built around.
"""
import pathlib, sys

P = pathlib.Path("papers/论文-慢层只读一次原则.md")
md = P.read_text(encoding="utf-8")
orig = md

REPL = [
    ("平凡的是这条原则的推导，不是它的骨架地位：",
     "平凡的是这条原则的推导，不是它的作用："),
    ("平凡的是这条原则的推导，不是它的骨架地位。",
     "平凡的是这条原则的推导，不是它的作用。"),
]
miss = []
for a, b in REPL:
    if a not in md:
        miss.append(a[-12:])
        continue
    md = md.replace(a, b)

left = md.count("骨架")
P.write_text(md, encoding="utf-8")
print("  替换 %d 处" % (len(REPL) - len(miss)))
for m in miss:
    print("  未匹配: ...%s" % m)
print("  残留「骨架」: %d" % left)
print("  篇幅变化 %+d 字符" % (len(md) - len(orig)))
if left:
    sys.exit("★ 仍有残留")
for i, l in enumerate(P.read_text(encoding="utf-8").splitlines(), 1):
    if "平凡的是" in l:
        j = l.find("平凡的是")
        print("  行%4d  …%s…" % (i, l.strip()[j:j + 60].replace("\n", " ")))