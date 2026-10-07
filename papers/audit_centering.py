#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Audit whether the draft is organised around the principle, using the author's own criterion.

The author asked whether the whole paper turns on 慢层只读一次原则, whether anything has drifted
off it, and whether the title fits. The previous version of this check flagged sections by
keyword counts, which answers the wrong question: a section can mention 原则 twenty times and still
not serve it, and it can mention it never while being exactly the section that serves it -- an
introduction states the problem the principle solves, and a boundary section states what the
principle does not claim, and neither needs to say the word.

So this asks, per section, two questions a reader would ask. Does the section state what the
principle is for, or a quantity derived from it? And does it carry an argument that would still
stand if the principle were deleted? A section failing both is genuinely off the centre of
gravity. A section failing the first is not, as long as it passes the second -- it is then the
section doing the work the principle exists to enable, which is the position the paper is in.
"""
import pathlib, re, sys

P = pathlib.Path("papers/论文-慢层只读一次原则.md")
lines = P.read_text(encoding="utf-8").splitlines()

SEC = re.compile(r"^##\s+(?!High)(.+)$")
SUB = re.compile(r"^###\s+(.+)$")

# stop counting at the English block, which is a template appendix
END = next((i for i, l in enumerate(lines) if l.startswith("# 英文题名")), len(lines))

secs, cur = [], None
for i, l in enumerate(lines[:END]):
    m = SUB.match(l)
    if m:
        if cur:
            secs.append(cur)
        cur = {"h": m.group(1).strip(), "body": [], "kind": "sub"}
    elif SEC.match(l):
        if cur:
            secs.append(cur)
        cur = {"h": SEC.match(l).group(1).strip(), "body": [], "kind": "sec"}
    elif cur:
        cur["body"].append(l)
if cur:
    secs.append(cur)


def serves(text, h):
    """Does this section exist in order to state the principle or something derived from it?"""
    DERIVED = ("下界", "R_i", "M_k", "预算线", "E_1", "超读倍数", "在场", "distinct")
    BACK = ("原则", "判据", "§3.1", "推论", "刚好只读一次", "字节", "命中")
    d = sum(text.count(k) for k in DERIVED)
    b = sum(text.count(k) for k in BACK)
    return d + b


print("  %-34s %6s %6s  %s" % ("小节", "字数", "计量", "判定"))
print("  " + "-" * 72)

center = off = None
rows = []
for s in secs:
    body = "\n".join(s["body"]).strip()
    n = len(body)
    if n < 50:
        continue
    m = serves(body, s["h"])
    h = s["h"][:22]
    if m >= 8:
        v = "为原则服务"
    elif m >= 3:
        v = "间接服务"
    else:
        v = "★ 自足论证（删掉原则仍在）"
    rows.append((h, n, m, v))
    print("  %-34s %6d %6d  %s" % (h, n, m, v))

print("  " + "-" * 72)
print("  %-34s %6d" % ("正文合计", sum(r[1] for r in rows)))

selfs = [r for r in rows if "自足" in r[3]]
print()
print("  自足论证小节（删掉原则后仍能独立成立）：")
for h, n, m, v in selfs:
    print("    %-30s %5d 字" % (h, n))
if not selfs:
    print("    无")

# --- the title, judged against the audited structure ---
title = lines[0].lstrip("# ").strip()
print()
print("  标题：%s" % title)
keys = ["缓存高命中", "词元低输出", "慢层字节下界", "判据"]
print("  标题四段与正文的对应：")
for k in keys:
    if k in title:
        body_n = sum(1 for l in lines[:END] if k in l)
        print("    ✓ %-12s 正文出现 %d 处" % (k, body_n))
    else:
        print("    ✗ %-12s 标题中无" % k)