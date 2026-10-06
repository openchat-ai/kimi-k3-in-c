#!/usr/bin/env python3
# 《计算机科学》asks for an abstract of 200-400 characters. Count the way a Chinese word count
# does: CJK ideographs each count 1, and a run of Latin/digits counts as one token rather than
# one per character -- otherwise "Kimi K3" and "25.83 GB" inflate a count that is meant to
# measure prose length. Both numbers are reported because the journal may count either way.
import re, sys, pathlib

p = pathlib.Path("papers/论文-慢层只读一次原则.md")
txt = p.read_text(encoding="utf-8")
m = re.search(r"## 摘要\s*\n\s*(.+?)\n## ", txt, re.S)
if not m:
    sys.exit("abstract section not found")
ab = m.group(1).strip()

cjk = len(re.findall(r"[\u4e00-\u9fff\u3000-\u303f\uff00-\uffef]", ab))
latin = len(re.findall(r"[A-Za-z0-9][A-Za-z0-9._%-]*", ab))
punct = len(re.findall(r"[，。、；：（）%\u2014\u2013\-\u201c\u201d]", ab))
loose = cjk + latin + punct
strict = cjk

print(f"  abstract characters (CJK only)        : {strict}")
print(f"  + Latin/number tokens, punctuation    : {loose}")
print()
for name, n in (("CJK only", strict), ("with tokens/punct", loose)):
    v = "OK  " if 200 <= n <= 400 else ("OVER" if n > 400 else "UNDER")
    print(f"  {name:<22} {n:>4}  {v}  (limit 200-400)")