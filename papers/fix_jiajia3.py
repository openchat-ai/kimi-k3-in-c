#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Drop the orphaned 地位 left by the previous positional replacement.

Replacing the two characters 骨架 with 作用 produced "作用地位", which is not a phrase. The
preceding positional fix was correct in method -- find by offset, report the surroundings, do not
guess at invisible characters -- but it replaced only the noun and left the qualifier that
belonged to it. This removes the qualifier and checks for the combined form rather than for
either part alone, since the previous check passed while the text was still wrong.
"""
import pathlib, sys

P = pathlib.Path("papers/论文-慢层只读一次原则.md")
md = P.read_text(encoding="utf-8")

REPL = [
    ("不是它的作用地位：", "不是它的作用："),
    ("不是它的作用地位。", "不是它的作用。"),
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
bad = md.count("作用地位")
print("  残留「作用地位」: %d" % bad)
for k, l in enumerate(P.read_text(encoding="utf-8").splitlines(), 1):
    if "平凡的是" in l:
        j = l.find("平凡的是")
        print("  行%4d  …%s…" % (k, l.strip()[j:j + 54]))
if bad:
    sys.exit("★ 仍有残留")