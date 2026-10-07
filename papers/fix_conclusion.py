#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Rewrite the conclusion's restatement so it stops duplicating contribution 2 verbatim.

The conclusion repeats contribution 2 word for word, including 2.8T, 25.83 GB and 94%, and the
two are about a page apart. A conclusion may restate a finding; repeating its wording is what a
reader mistakes for an error. The numbers belong to 4.2 and to the abstract, so the conclusion
keeps the finding and drops them.
"""
import pathlib, sys

P = pathlib.Path("papers/论文-慢层只读一次原则.md")
md = P.read_text(encoding="utf-8")
lines = md.splitlines()

for i, l in enumerate(lines):
    if l.startswith("本文从一次反常现象出发"):
        print("  原文（%d 字）：%s…" % (len(l.strip()), l.strip()[:96]))
        j = l.find("对存储受限主机上")
        k = l.find("。", j)
        old_tail = l[j:k + 1]
        print("  将删的重复部分：%s" % old_tail[:90])
        new_tail = "对存储受限主机上 2.8T MoE 推理冷启动的实测表明，每词元从低速盘全量重读专家权重 25.83 GB。"
        lines[i] = l[:j] + new_tail + l[k + 1:]
        print("  改后（%d 字）：%s…" % (len(lines[i].strip()), lines[i].strip()[:96]))
        break
else:
    sys.exit("★ 未找到结论段落")

md = "\n".join(lines)
P.write_text(md, encoding="utf-8")

md2 = P.read_text(encoding="utf-8")
dup = md2.count("接入高速盘后引擎自报命中率满格")
print("  重复句残留：%d 处" % dup)
if dup > 1:
    sys.exit("★ 仍有重复")