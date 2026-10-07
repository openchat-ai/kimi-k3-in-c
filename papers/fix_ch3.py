#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Remove the old 5.6 and repoint every reference to it.

The cross-validation rule now lives in 3.2, because the argument it supports is the bound's: a
bound is only as good as the counters that check it, so the two belong in the same chapter
rather than in a final section that reads as an appendix.

The old section is deleted by line range located from its heading to the next chapter heading,
not by text matching, so it cannot fail half-way the way the earlier whole-sentence replacements
did. References are then repointed before the deletion, while the anchor text is still readable
in context.
"""
import pathlib, re, sys

P = pathlib.Path("papers/论文-慢层只读一次原则.md")
lines = P.read_text(encoding="utf-8").splitlines()

# ---- 1. locate the old 5.6 by heading ----
start = end = None
for i, l in enumerate(lines):
    if l.startswith("### 5.6"):
        start = i
    elif start is not None and l.startswith("## 6 结论"):
        end = i
        break
if start is None or end is None:
    sys.exit("★ 定位失败：start=%s end=%s" % (start, end))
removed = lines[start:end]
print("  删除 §5.6：行 %d..%d，共 %d 行 / %d 字" % (start + 1, end, len(removed),
                                              sum(len(x.strip()) for x in removed)))

# ---- 2. repoint references, before deleting ----
REFS = [
    ("§5.6", "§3.2"),
    ("5.6 节", "3.2 节"),
    ("见 5.6", "见 3.2"),
    ("（第 4.6、5.2 节）", "（第 4.6、5.2 节）"),
]
body = lines[:start] + lines[end:]
txt = "\n".join(body)
nrefs = 0
for a, b in REFS:
    if a != b:
        n = txt.count(a)
        nrefs += n
        txt = txt.replace(a, b)
print("  重定向引用 %d 处" % nrefs)

# ---- 3. chapter 5 title no longer promises instrumentation ----
old5 = "## 5 下界的工程用法：预算、验收与排查"
new5 = "## 5 判据的工程用法：预算、验收与排查"
if old5 in txt:
    txt = txt.replace(old5, new5)
    print("  第 5 章题名已改")

# ---- 4. chapter 4 title: it now verifies the criterion, not a principle ----
old4 = "## 4 原则的实证验证：MoE 推理平台"
new4 = "## 4 判据的实证：MoE 推理平台"
if old4 in txt:
    txt = txt.replace(old4, new4)
    print("  第 4 章题名已改")

P.write_text(txt, encoding="utf-8")

# ---- 5. verify nothing dangles ----
left = txt.count("§5.6") + txt.count("5.6 节")
print("  残留 §5.6 引用: %d" % left)
print("  新 §3.2 引用: %d 处" % len(re.findall(r"§?3\.2", txt)))
if left:
    sys.exit("★ 仍有悬空引用")
print("  新总行数 %d" % len(txt.splitlines()))