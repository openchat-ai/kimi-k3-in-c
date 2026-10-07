#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Report anything in the paper that reads as a work log rather than as a paper."""
import re, pathlib

md = pathlib.Path("papers/论文-慢层只读一次原则.md").read_text(encoding="utf-8")
lines = md.splitlines()

LOG = r"撤回|已删除|作废|一并记录|此前据|先前引用|此前写入|予以撤回|经四次修正|本节结论改写|不再出现在|随本节一并|本节曾支撑"
print("== 日志腔用语")
n = 0
for i, l in enumerate(lines, 1):
    m = re.findall(LOG, l)
    if m:
        print("  第 %d 行: %s" % (i, " / ".join(m)))
        n += 1
if n == 0:
    print("  无")

print()
print("== 日期戳")
d = re.findall(r"20\d\d-\d\d-\d\d", md)
print("  %d 处%s" % (len(d), ("  " + ", ".join(sorted(set(d)))) if d else ""))

print()
print("== 乱码")
b = [i for i, l in enumerate(lines, 1) if "\ufffd" in l]
print("  %s" % ("第 %s 行" % ", ".join(map(str, b)) if b else "无"))

print()
paras = [l for l in lines if l.strip() and not l.strip().startswith(("|", "```", "#"))]
print("== 规模")
print("  段落 %d   加粗 %d   问号 %d   '本文' %d"
      % (len(paras), md.count("**") // 2, md.count("？"),
         len(re.findall(r"本文", "\n".join(paras)))))