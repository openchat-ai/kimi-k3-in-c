#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""List the longest sentences so the rewriting can be aimed at real offenders."""
import re, pathlib

lines = pathlib.Path("papers/论文-慢层只读一次原则.md").read_text(encoding="utf-8").splitlines()
out = []
for i, ln in enumerate(lines, 1):
    s = ln.strip()
    if not s or s.startswith(("|", "```", "#")) or "**" in s:
        continue
    for sent in re.split(r"。", s):
        sent = sent.strip()
        if len(sent) >= 95:
            out.append((len(sent), i, sent))
out.sort(reverse=True)
print("  超长句（正文，不含加粗与标题）共 %d 句，列出前 10" % len(out))
for L, i, s in out[:10]:
    print()
    print("  [%3d 字 · 第 %d 行]" % (L, i))
    print("    %s" % s[:300])