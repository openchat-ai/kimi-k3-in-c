#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Report the chapter balance after the restructure.

The point of measuring this is that the previous arrangement was lopsided in a specific way: a
chapter devoted to a three-step derivation stood next to a chapter of evidence that was four
times its length. If the reorganisation did not move that ratio, it did not accomplish anything.
"""
import pathlib, re, sys

P = pathlib.Path("papers/论文-慢层只读一次原则.md")
md = P.read_text(encoding="utf-8")

CH = [("## 1 引言", "## 2 相关工作", "1 引言"),
      ("## 2 相关工作", "## 3 判据", "2 相关工作"),
      ("## 3 判据", "## 4 判据", "3 判据与可验证性"),
      ("## 4 判据", "## 5 判据", "4 实证"),
      ("## 5 判据", "## 6 结论", "5 工程用法"),
      ("## 6 结论", "## 附录", "6 结论")]

print("  章          字数")
tot = 0
for a, b, name in CH:
    if a not in md or b not in md:
        print("  ★ 定位失败 %s / %s" % (a, b))
        sys.exit(1)
    n = len(md.split(a)[1].split(b)[0].strip())
    tot += n
    print("  %-14s %5d" % (name, n))
print("  %-14s %5d" % ("正文合计", tot))

print()
e = len(md.split("## 4 判据")[1].split("## 5 判据")[0].strip())
u = len(md.split("## 5 判据")[1].split("## 6 结论")[0].strip())
print("  证据 : 用法 = %d : %d = %.2f" % (e, u, e / u))
print("  （改前为 8482 : 5905 = 1.44）")

print()
heads = re.findall(r"^#{1,3} .+$", md, re.M)
print("  标题 %d 个" % len(heads))
for h in heads:
    if h.startswith("## ") and not h.startswith("### "):
        print("    " + h)