#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Remove the two first-person passages in 1.1.

第一人称 is not forbidden in the body -- the journal's rule applies to the abstract only -- but
the draft carried 我们 twice while using 本文 thirty-seven times elsewhere, so the two sections
that introduced the problem were written in a different voice from the rest.

The replacements keep the epistemic content, which is the part that matters here: these are
statements about what was observed and what was then pursued, and they lose nothing by being
attributed to the work rather than to the authors. The lede in particular has to survive as a
statement of the situation, not as an anecdote about who hit it.
"""
import pathlib, sys

P = pathlib.Path("papers/论文-慢层只读一次原则.md")
md = P.read_text(encoding="utf-8")
orig = md

REPL = [
    ("按这一前提优化缓存时，我们遇到了一个反常现象：",
     "按这一前提优化缓存时出现了一个反常现象："),
    ("这一现象促使我们追溯底层机制：",
     "这一现象促使后续工作追溯底层机制："),
]
miss = []
for a, b in REPL:
    if a not in md:
        miss.append(a)
        continue
    md = md.replace(a, b)

P.write_text(md, encoding="utf-8")
print("  替换 %d 处" % (len(REPL) - len(miss)))
for m in miss:
    print("  未匹配: %s" % m)
print("  篇幅变化 %+d 字符" % (len(md) - len(orig)))

left = [w for w in ("我们", "笔者", "我方", "本人") if w in md]
print("  残留第一人称: %s" % (left if left else "无"))
if left:
    sys.exit("★ 仍有第一人称")
print()
for k, l in enumerate(P.read_text(encoding="utf-8").splitlines(), 1):
    if k in (22, 26):
        s = l.strip()
        print("  行%4d  %s…" % (k, s[:76]))