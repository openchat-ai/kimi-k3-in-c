#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Compare the author's original title with the ones I proposed."""
import re

T = [
    ("作者原题", "缓存高命中与词元低输出：慢层字节下界判据"),
    ("我改的", "缓存高命中与词元低输出：字节级验收方法与一条平凡下界"),
    ("我推荐 #4", "缓存高命中与词元低输出：字节量而非命中率"),
    ("我推荐 #3", "缓存高命中与词元低输出：字节量核算与诊断"),
]
print("  %-12s %-4s %-4s %s" % ("", "汉字", "总长", "题名"))
for name, t in T:
    h = len(re.findall(r"[\u4e00-\u9fff]", t))
    print("  %-12s %-5d %-5d %s" % (name, h, len(t), t))

orig = T[0][1]
mine = T[1][1]
print()
print("  原题 %d 汉字，我改后 %d 汉字 —— 我加了 %d 字"
      % (len(re.findall(r"[\u4e00-\u9fff]", orig)),
         len(re.findall(r"[\u4e00-\u9fff]", mine)),
         len(re.findall(r"[\u4e00-\u9fff]", mine)) - len(re.findall(r"[\u4e00-\u9fff]", orig))))
print("  我推荐的 #4 比原题长 %d 字，比我改的短 %d 字"
      % (len(re.findall(r"[\u4e00-\u9fff]", T[2][1])) - len(re.findall(r"[\u4e00-\u9fff]", orig)),
         len(re.findall(r"[\u4e00-\u9fff]", mine)) - len(re.findall(r"[\u4e00-\u9fff]", T[2][1]))))