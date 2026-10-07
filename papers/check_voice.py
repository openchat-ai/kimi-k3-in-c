#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Check voice consistency across the whole draft.

第一人称 is permitted in the body and forbidden in the abstract, so a count of the whole file
would be the wrong test -- it would flag a legitimate use. What matters is that the draft does
not switch voice between sections, and that the abstract stays clean regardless of what the body
does. Both are checked here, and the abstract is checked by its own line rather than by inference.
"""
import pathlib, re, sys

P = pathlib.Path("papers/论文-慢层只读一次原则.md")
lines = P.read_text(encoding="utf-8").splitlines()
md = "\n".join(lines)
PRON = ("我们", "笔者", "我方", "本人", "笔者们")

# ---- the abstract, by line ----
ab_start = next(i for i, l in enumerate(lines) if l.strip() == "## 摘要")
ab_end = next(i for i, l in enumerate(lines[ab_start + 1:], ab_start + 1)
              if re.match(r"^#{1,2} ", l))
ab = "\n".join(lines[ab_start + 1:ab_end])
ab_bad = [w for w in PRON if w in ab]

print("  摘要（第 %d..%d 行，%d 字）" % (ab_start + 1, ab_end, len(ab.strip())))
print("    第一人称: %s" % (ab_bad if ab_bad else "无 ✓（模板要求不用第一人称）"))
if ab_bad:
    sys.exit("★ 摘要含第一人称")

# ---- voice by section ----
print()
print("  正文各节的语态")
secs, cur = [], None
for i, l in enumerate(lines):
    if re.match(r"^#{2,3} ", l):
        if cur:
            secs.append(cur)
        cur = {"h": l.strip()[3:], "body": [l]}
    elif cur:
        cur["body"].append(l)
if cur:
    secs.append(cur)

END = next((i for i, l in enumerate(lines) if l.startswith("# 英文题名")), len(lines))
bad = 0
for s in secs:
    body = "\n".join(s["body"])
    if "英文题名" in s["h"]:
        continue
    if s["body"] and s["body"][0] is lines[END] if END < len(lines) else False:
        continue
    hits = {w: body.count(w) for w in PRON if body.count(w)}
    n = len(body.strip())
    if n < 50:
        continue
    if hits:
        bad += 1
        print("    ★ %-30s %s" % (s["h"][:28], hits))
print("    语态不统一的小节: %d" % bad)

# ---- the reference voice actually used ----
print()
print("  全文第三人称自指用词")
for w in ("本文", "本节", "本章", "该判据", "上述"):
    print("    %-6s ×%d" % (w, md.count(w)))
if bad:
    sys.exit("★ %d 个小节语态不一致" % bad)
print()
print("  语态全文统一")