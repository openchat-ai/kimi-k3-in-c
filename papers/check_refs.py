#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Count in-text citations so the bibliography can be cut without leaving dangling markers.

The template asks for 只择最主要的列入. Which ones those are cannot be guessed: a reference
that is never cited in the body can be deleted outright, while one that IS cited can only go
if its in-text marker goes with it. This prints both lists and nothing is removed.
"""
import re, pathlib

md = pathlib.Path("papers/论文-慢层只读一次原则.md").read_text(encoding="utf-8")

m = re.search(r"^## 参考文献\s*$", md, re.M)
body, reflist = md[:m.start()], md[m.start():]

refs = re.findall(r"(?m)^\[(\d+)\]\s*(.+)$", reflist)
print("  in-text citation count (UNUSED = safe to delete)")
print("  " + "-" * 74)
rows = []
for n, txt in refs:
    n = int(n)
    cited = len(re.findall(r"\[%d\]" % n, body))
    rows.append((n, cited, len(txt), txt))
for n, cited, ln, txt in sorted(rows, key=lambda r: (r[1], r[0])):
    mark = "UNUSED" if cited == 0 else "x%d" % cited
    print("  [%2d] %-8s%4d ch  %s" % (n, mark, ln, txt[:56]))
print("  " + "-" * 74)

unused = [r for r in rows if r[1] == 0]
used = [r for r in rows if r[1] > 0]
print("  UNUSED : %d entries, %d chars"
      % (len(unused), sum(r[2] for r in unused)))
print("  CITED  : %d entries, %d chars"
      % (len(used), sum(r[2] for r in used)))
print("  used   : %s" % ", ".join(str(r[0]) for r in used))
print("  unused : %s" % ", ".join(str(r[0]) for r in unused))

print()
print("  path check on every cited reference:")
for n, cited, ln, txt in rows:
    for path in re.findall(r"[\w./-]+\.(?:md|sh|py)", txt):
        print("    [%2d] %-46s %s"
              % (n, path, "EXISTS" if pathlib.Path(path).exists() else "*** MISSING ***"))