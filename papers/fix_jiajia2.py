#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Replace the last 骨架 by position rather than by literal match.

The literal replacements both failed while the file plainly contains the string, which means the
bytes around it are not what the pattern assumed. Rather than keep guessing at invisible
characters, find the two characters by offset, report what surrounds them, and rewrite the span
in place. This is the same lesson as the earlier failed whole-sentence matches: when the anchor
does not match, the anchor is wrong, not the intent.
"""
import pathlib, sys

P = pathlib.Path("papers/论文-慢层只读一次原则.md")
md = P.read_text(encoding="utf-8")

i = md.find("骨架")
if i < 0:
    print("  无「骨架」，无需处理")
    sys.exit(0)

print("  命中位置 %d，前文: %r" % (i, md[i - 30:i]))
print("  命中位置 %d，后文: %r" % (i, md[i:i + 30]))

md = md[:i] + "作用" + md[i + 2:]
left = md.count("骨架")
P.write_text(md, encoding="utf-8")
print("  替换完成，残留「骨架」: %d" % left)

for k, l in enumerate(P.read_text(encoding="utf-8").splitlines(), 1):
    if "平凡的是" in l:
        j = l.find("平凡的是")
        print("  行%4d  …%s…" % (k, l.strip()[j:j + 56]))
if left:
    sys.exit("★ 仍有残留")