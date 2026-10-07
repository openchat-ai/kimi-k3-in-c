#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Audit the status of 原则 across the draft, against the intended state rather than a blacklist.

The previous version of this check listed every occurrence but judged them with a regex
blacklist, which meant the sentence "平凡的是这条原则的推导，不是它的骨架地位" was flagged as a
demotion even though it is the sentence that reconciles the principle being trivially derived
with the principle being load-bearing. A blacklist cannot tell a demotion from the reconciliation
of one, so it reported the intended sentence as a defect and I "fixed" it twice, each time
removing the qualification the argument needed.

The intended state is a whitelist: 原则 must be the name of the bound throughout, and the only
permitted qualifications are the ones that separate the triviality of its derivation from its
structural role. Anything demoting the principle itself -- calling it an empirical regularity,
saying it is insufficient to be a contribution, saying it is not being claimed as a result --
is still a defect.
"""
import pathlib, re, sys

P = pathlib.Path("papers/论文-慢层只读一次原则.md")
md = P.read_text(encoding="utf-8")
lines = md.splitlines()

# ---- what must not appear anywhere ----
FORBIDDEN = [
    ("经验规律\"慢速层只读一次\"", "降格为经验规律"),
    ("慢速层只读一次\"作为经验规律", "以经验规律口吻指称原则"),
    ("不足以独立构成贡献", "自称不足以构成贡献"),
    ("而不是把它当作结果", "自称不作为结果"),
    ("组织为经验规律", "自称经验规律"),
    ("### 3.1 下界（引理）", "小节题名仍为引理"),
    ("## 3 判据：下界与可验证性", "章题名已无原则"),
]

# ---- what must appear, since these carry the argument ----
REQUIRED = [
    ("平凡的是这条原则的推导，不是它的作用", "区分推导平凡与作用"),
    ("慢速层只读一次原则（§3.1）", "1.2 以原则指称标尺"),
    ("### 3.1 原则：慢速层只读一次", "3.1 小节题名"),
    ("## 3 慢速层只读一次原则：下界与可验证性", "第 3 章题名"),
]

print("  必须存在")
missing = 0
for needle, name in REQUIRED:
    n = md.count(needle)
    ok = n > 0
    if not ok:
        missing += 1
    print("    %s  %-28s ×%d" % ("✓" if ok else "★", name, n))

print()
print("  必须不存在")
bad = 0
for needle, name in FORBIDDEN:
    n = md.count(needle)
    if n:
        bad += 1
    print("    %s  %-28s ×%d" % ("★" if n else "✓", name, n))

print()
print("  「原则」出现 %d 处；「慢速层只读一次原则」全称 %d 处；「引理」%d 处"
      % (md.count("原则"), md.count("慢速层只读一次原则"), md.count("引理")))
for i, l in enumerate(lines, 1):
    if "引理" in l:
        print("    引理 行%4d  %s" % (i, l.strip()[:74]))

if missing or bad:
    sys.exit("★ 缺失 %d 项，存在 %d 项禁止项" % (missing, bad))
print()
print("  原则的地位全文一致")