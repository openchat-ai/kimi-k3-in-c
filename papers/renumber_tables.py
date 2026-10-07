#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Renumber every table caption by position, and fix the in-text references.

The previous attempt numbered the new captions first and then shifted the old ones, which
produced [1, 2, 4, 5, 6, 3, 8, 4] -- correct captions, wrong order. Numbering a table by where
it is in the document is the only definition that cannot come out this way, so this pass
discards the existing numbers and reissues them from the position of each table's separator row.

In-text references are remapped through the same table: the reference is recorded as pointing at
whichever caption sits nearest above the line containing it, not by its old number.
"""
import pathlib, re, sys

P = pathlib.Path("papers/论文-慢层只读一次原则.md")
lines = P.read_text(encoding="utf-8").splitlines()
END = next((i for i, l in enumerate(lines) if l.startswith("# 英文题名")), len(lines))

SEP = re.compile(r"^\|\s*:?-{2,}")
CAPCN = re.compile(r"^表\s*\d+(\u3000.*)$")
CAPEN = re.compile(r"^Table\s*\d+(\u3000.*)$")

# ---- 1. locate tables and their captions ----
tabs = []          # (sep_index, cn_text, en_text, cn_index, en_index)
for i in range(END):
    if not SEP.match(lines[i]):
        continue
    cn = en = None
    cn_i = en_i = None
    j = i - 1
    while j >= 0:
        s = lines[j].strip()
        if not s:
            j -= 1
            continue
        m = CAPCN.match(s)
        if m:
            cn, cn_i = m.group(1), j
        m = CAPEN.match(s)
        if m:
            en, en_i = m.group(1), j
        if cn and en:
            break
        j -= 1
    tabs.append({"sep": i, "cn": cn, "en": en, "cn_i": cn_i, "en_i": en_i})

print("  表 %d 张（按文中位置）" % len(tabs))

# ---- 2. issue numbers, and build the old->new map ----
remap = {}
for n, t in enumerate(tabs, 1):
    old_cn = lines[t["cn_i"]].strip() if t["cn_i"] is not None else None
    old_en = lines[t["en_i"]].strip() if t["en_i"] is not None else None
    m_old = re.match(r"^表\s*(\d+)", old_cn or "")
    if m_old:
        remap[int(m_old.group(1))] = n
    print("    %d. %s" % (n, (t["cn"] or "★ 无题名")[:52]))
    t["new"] = n

print("  旧号→新号：%s" % remap)

# ---- 3. rewrite captions ----
for t in tabs:
    if t["cn"] is not None:
        lines[t["cn_i"]] = "表 %d%s" % (t["new"], t["cn"])
    if t["en"] is not None:
        lines[t["en_i"]] = "Table %d%s" % (t["new"], t["en"])

md = "\n".join(lines) + "\n"

# ---- 4. fix in-text references, highest old number first so 8 -> 7 does not
#         get re-matched by a later 7 -> 6 rule ----
for old in sorted(remap, reverse=True):
    new = remap[old]
    if old == new:
        continue
    before = md
    md = re.sub(r"表 %d(?![\d\u3000])" % old, "表 %d" % new, md)
    md = re.sub(r"Table %d(?![\d\u3000])" % old, "Table %d" % new, md)
    if md != before:
        print("  正文引用 表 %d → 表 %d" % (old, new))

P.write_text(md, encoding="utf-8")

# ---- 5. verify ----
md2 = P.read_text(encoding="utf-8")
cn = [int(m) for m in re.findall(r"^表\s*(\d+)\u3000", md2, re.M)]
en = [int(m) for m in re.findall(r"^Table\s*(\d+)\u3000", md2, re.M)]
want = list(range(1, len(cn) + 1))
print()
print("  中文题名 %s" % cn)
print("  英文题名 %s" % en)
print("  应为     %s" % want)
if cn != want or en != want:
    sys.exit("★ 编号仍不连续")
print("  ✓ 编号连续，中英一一对应，共 %d 张" % len(cn))

# no stray old numbers in prose
stray = set(int(m) for m in re.findall(r"(?<![\d.])(?:表|Table)\s*(\d+)", md2))
print("  全文出现的表号：%s" % sorted(stray))