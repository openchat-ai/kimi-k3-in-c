#!/usr/bin/env python3
# -*- coding: utf-8 -*-
import re, pathlib

md = pathlib.Path("papers/论文-慢层只读一次原则.md").read_text(encoding="utf-8")
body = "\n".join(l for l in md.splitlines()
                 if l.strip() and not l.strip().startswith(("|", "```", "#")))

for w in ["了", "吗", "呢", "有的", "不是", "而是", "之所以", "其实",
          "先问", "可见", "换句话说", "值得", "偏偏", "竟然", "却"]:
    print("  %-6s %4d" % (w, body.count(w)))
print()
print("  整篇问句（含？）：%d" % body.count("？"))
print("  排比「A、B、C 而 D」：%d" % len(re.findall(r"而[^。]{0,20}，而", body)))
print("  转折连用「虽然…但是/但」：%d" % len(re.findall(r"虽然[^。]{0,60}但", body)))