#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Find compressible redundancy in the body: repeated claims, near-duplicate sentences,
and repeated numeric facts. Legitimate compression works on the author's own wording."""
import re, pathlib, collections, difflib

md = pathlib.Path("papers/论文-慢层只读一次原则.md").read_text(encoding="utf-8")

m = re.search(r"^## 参考文献\s*$", md, re.M)
body = md[:m.start()]

# keep only the six numbered body sections, so back matter and the pointer do not pollute counts
secs = {}
cur = None
for ln in body.splitlines():
    s = ln.strip()
    mm = re.match(r"^## (\d)\s+(\S.*)$", s)
    if mm:
        cur = "§" + mm.group(1) + " " + mm.group(2)[:14]
        secs[cur] = []
    elif cur and s:
        secs[cur].append(s)
print("  正文各节字符数")
tot = 0
for k, v in secs.items():
    n = sum(len(x) for x in v)
    tot += n
    print("    %-24s %5d 字符  段落 %2d" % (k, n, len(v)))
print("    %-24s %5d 字符" % ("正文合计", tot))

text = "\n".join(body.splitlines())

# ---- 1. repeated numeric facts ----
print()
print("  反复出现的数字（同一事实说 N 遍 = N-1 处可合并）")
facts = collections.Counter(re.findall(r"\d[\d,.]*\s*(?:GB|MB|GB/词元|%)", text))
for f, c in facts.most_common(14):
    if c >= 3:
        print("    %-14s ×%d" % (f, c))

# ---- 2. near-duplicate sentences ----
sents = [s for s in re.split(r"[。；;！!？?]", text) if len(s.strip()) >= 22]
print()
print("  近重复句（相似度 ≥0.72，≥18 字）")
seen, dup = set(), []
for i, a in enumerate(sents):
    for b in sents[i + 1:]:
        if abs(len(a) - len(b)) > 30:
            continue
        r = difflib.SequenceMatcher(None, a, b).ratio()
        if r >= 0.72:
            dup.append((r, a.strip(), b.strip()))
dup.sort(reverse=True, key=lambda t: t[0])
shown = 0
for r, a, b in dup:
    key = (a[:20], b[:20])
    if key in seen:
        continue
    seen.add(key)
    print("    %.2f  A: %s" % (r, a[:76]))
    print("          B: %s" % b[:76])
    shown += 1
    if shown >= 8:
        break
if not shown:
    print("    未发现近重复句")

# ---- 3. the addendum sections, which are where additions accumulate ----
print()
print("  增补型小节（后加的，最可能是可合并的对象）")
for k, v in secs.items():
    for x in v:
        if re.match(r"^\d+\.\d+(\.\d+)?\s*补[:：]", x) or "补：" in x[:8]:
            print("    %s → %s" % (k, x[:70]))