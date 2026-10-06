#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Show where each cited reference is used, so trimming does not remove load-bearing support."""
import re, pathlib

md = pathlib.Path("papers/论文-慢层只读一次原则.md").read_text(encoding="utf-8")
m = re.search(r"^## 参考文献\s*$", md, re.M)
body, reflist = md[:m.start()], md[m.start():]
refs = dict((int(n), t) for n, t in re.findall(r"(?m)^\[(\d+)\]\s*(.+)$", reflist))

TARGETS = [int(x) for x in __import__("sys").argv[1:]] or sorted(refs)
for n in TARGETS:
    print("  [%d] %s" % (n, refs.get(n, "?")[:70]))
    hits = 0
    for mo in re.finditer(r"\[%d\]" % n, body):
        s = max(0, mo.start() - 110)
        e = min(len(body), mo.end() + 60)
        frag = body[s:e].replace("\n", " ")
        print("      …%s…" % frag)
        hits += 1
    if not hits:
        print("      （正文未引用）")
    print()