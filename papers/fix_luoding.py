#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Fix the last 落层位置, which sits inside the abstract's list of the four triage steps.

The four steps are named in the abstract as 算法免读→缓存复用→落层位置→落层前压缩. Step ③ is
headlined 落位层 everywhere else, including in 5.3 itself, so the abstract lists the four steps
under a name that differs from the headings the reader will meet. The other three steps are
headlines verbatim, which is why this one stands out.
"""
import pathlib, sys

P = pathlib.Path("papers/论文-慢层只读一次原则.md")
md = P.read_text(encoding="utf-8")

a = '"算法免读→缓存复用→落层位置→落层前压缩"'
b = '"算法免读→缓存复用→落位层→落层前压缩"'
n = md.count(a)
if not n:
    sys.exit("★ 未找到四步列表")
md = md.replace(a, b)
P.write_text(md, encoding="utf-8")
print("  替换 %d 处" % n)

md2 = P.read_text(encoding="utf-8")
print("  残留「落层位置」: %d" % md2.count("落层位置"))
if md2.count("落层位置"):
    sys.exit("★ 仍有残留")
print("  摘要四步：%s" % [s for s in md2.splitlines() if "算法免读" in s][0][
      md2.splitlines()[[i for i, s in enumerate(md2.splitlines())
                        if "算法免读" in s][0]].find("算法免读"):
      md2.splitlines()[[i for i, s in enumerate(md2.splitlines())
                        if "算法免读" in s][0]].find("算法免读") + 34])