#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Audit two things the author raised: repository paths, and numbers living only in prose.

The repository paths matter because they do not travel with a submission -- the editor receives
a DOCX and a PDF attachment, so a citation to reports/gateab_ab/... is a dead end in print.

The numbers matter for a related reason. A quantity that appears only in the prose has no home: the
reader is asked to hold a figure in their head, and if they want to check it against anything they
cannot, because there is no table row to compare it with. Guideline item 17 asks for the
reproduction material as an attachment precisely so the body can cite evidence the reader holds in
hand -- but a raw file path is not that.

This lists every path left in the body, and every quantity in the prose whose value does not occur
anywhere in that section's tables or figures, so the prose can be cut back to what the tables do
not already say.
"""
import pathlib, re, sys

P = pathlib.Path("papers/论文-慢层只读一次原则.md")
lines = P.read_text(encoding="utf-8").splitlines()
END = next((i for i, l in enumerate(lines) if l.startswith("# 英文题名")), len(lines))

# ================= 1. repository paths =================
PATH = re.compile(r"`([^`]+)`")
print("=" * 76)
print("  1  正文中的反引号内容（逐个判定是路径还是技术量）")
repo = []
for i, l in enumerate(lines[:END], 1):
    for m in PATH.finditer(l):
        v = m.group(1)
        looks_path = "/" in v or v.endswith((".txt", ".md", ".json", ".out"))
        if looks_path or re.search(r"reports|BENCH_PROTO|FINDINGS|\bv\d+_", v):
            repo.append((i, v, l.strip()))
            print("    ★ 行%-4d %-42s" % (i, v))
print("    需处理 %d 处" % len(repo))

# ================= 2. quantities with no table or figure =================
print()
print("=" * 76)
print("  2  正文数字是否能在本节表/图中找到")

# section boundaries
SEC = re.compile(r"^###?\s")
secs, cur = [], None
for i, l in enumerate(lines[:END]):
    if SEC.match(l):
        if cur:
            secs.append(cur)
        cur = {"h": l.strip()[3:40], "i": i, "body": []}
    elif cur:
        cur["body"].append((i + 1, l))
if cur:
    secs.append(cur)

# all table rows in the document, per section
QTY = re.compile(r"\b\d+(?:[.,]\d+)?\s*(?:GB|MB|KB|s\b|秒|次|词元|%|倍|层|行|对|轮)")

for s in secs:
    if len(s["body"]) < 6:
        continue
    txt = "\n".join(l for _, l in s["body"])
    # a note under a table or figure is part of that table's home, and a figure's caption and
    # alt text describe what it plots -- both count as somewhere the reader can look
    tbl_blob = "\n".join(l for _, l in s["body"]
                         if l.strip().startswith("|") or l.strip().startswith("注："))
    fig_blob = "\n".join(l for _, l in s["body"]
                         if l.strip().startswith("图") or l.strip().startswith("!["))
    home = re.findall(r"\d+(?:\.\d+)?", tbl_blob + fig_blob)
    home_set = set(home)
    orphans = {}
    for ln, l in s["body"]:
        if l.strip().startswith("|") or l.strip().startswith("图"):
            continue
        for m in QTY.finditer(l):
            v = re.match(r"(\d+(?:[.,]\d+)?)", m.group(0)).group(1).replace(",", "")
            if "." in v or len(v) >= 3:
                if v not in home_set and v.replace(".", "") not in \
                        {x.replace(".", "") for x in home_set}:
                    orphans.setdefault(v, []).append(ln)
    if orphans:
        tot = sum(len(v) for v in orphans.values())
        print()
        print("    %s  （%d 个数值无表/图支撑）" % (s["h"], tot))
        for v, lns in sorted(orphans.items(), key=lambda kv: -len(kv[1]))[:14]:
            print("      %-10s ×%-3d 行 %s" % (v, len(lns), lns[:6]))