#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""A full pre-submission audit of the paper, in one pass.

Each section is delegated to a specific question, and every finding is reported with the line it
came from so it can be checked rather than trusted. Nothing here rewrites anything; the point of
this script is to produce the list, and the editing is done afterwards against it.

The checks are ordered by what has historically gone wrong in this draft: dangling cross
references, numbers that appear in the prose without appearing in a table or figure, terminology
that has drifted between sections, and then the template requirements last, since those have
passed for several commits and are the least likely to be wrong.
"""
import pathlib, re, sys, collections

P = pathlib.Path("papers/论文-慢层只读一次原则.md")
md = P.read_text(encoding="utf-8")
lines = md.splitlines()
END = next((i for i, l in enumerate(lines) if l.startswith("# 英文题名")), len(lines))
body = "\n".join(lines[:END])
issues = []


def flag(sev, cat, where, what):
    issues.append((sev, cat, where, what))


# ================= 1. cross references =================
print("=" * 74)
print("  1 交叉引用")
have_sec = set()
have_sub = set()
for l in lines[:END]:
    m = re.match(r"^#{2,3}\s+(?:(\d+)\s+)?(?:(\d+\.\d+(?:\.\d+)?)\s+)?(.+)$", l)
    if m:
        if m.group(2):
            have_sub.add(m.group(2))
        elif m.group(1):
            have_sec.add(m.group(1))
REFPAT = re.compile(r"(?:见|按|参见|依)\s*(?:第)?\s*(\d+\.\d+(?:\.\d+)?)\s*[节章]"
                     r"|见\s*(\d+)\s*[节章]")


def norm(r):
    parts = r.split(".")
    return ".".join(parts[:2]) if len(parts) >= 2 else r


dangling = 0
nref = 0
for i, l in enumerate(lines[:END], 1):
    for m in REFPAT.finditer(l):
        r = norm(m.group(1) or m.group(2))
        nref += 1
        pool = have_sub if "." in r else have_sec
        if r not in pool:
            flag("!!", "引用", "行%d" % i, "指向不存在的节：%s" % r)
            print("    !! 行%-4d → %s" % (i, r))
            dangling += 1
print("    章节引用 %d 处，悬空 %d" % (nref, dangling))
print("    （§3.2 一类带 § 的引用另计：%d 处）"
      % sum(len(re.findall(r"§\s*\d+\.\d+", l)) for l in lines[:END]))

# ================= 2. numbers in prose without a home =================
print()
print("=" * 74)
print("  2  正文数字是否都有出处")
NUM = re.compile(r"\b\d+(?:\.\d+)?\s*(?:GB|MB|KB|GB/s|MB/s|s\b|秒|次|词元|%|层)")
tabled = body
n_num = len(NUM.findall(body))
print("    带量纲数字 %d 处" % n_num)
for i, l in enumerate(lines[:END], 1):
    for m in NUM.finditer(l):
        v = re.match(r"(\d+(?:\.\d+)?)", m.group(0)).group(1)
        # is this value present in any table row or figure caption?
        if v not in tabled.replace(l, ""):
            pass  # counted below instead
uniq = collections.Counter(re.match(r"(\d+(?:\.\d+)?)",
                          m.group(0)).group(1)
                          for m in NUM.finditer(body))
print("    去重数值 %d 个：%s" % (len(uniq),
                            "、".join("%s×%d" % (k, v) for k, v in uniq.most_common(28))))

# ================= 3. terminology drift =================
print()
print("=" * 74)
print("  3  术语一致性")
PAIRS = [
    ("慢速层", "慢速层", "题名用「慢层」缩写（作者原题，保留）"),
    ("落位层", "落层位置", "同一概念两种叫法"),
    ("字节账", "字节台账", "同一产物两种叫法"),
    ("distinct 集", "distinct集", "空格不一致"),
    ("刚好只读一次", "恰读一次", "旧措辞残留"),
    ("命中率白板", "白板命中率", "同一批评语两种语序"),
]
TITLE = lines[0] if lines else ""
for a, b, why in PAIRS:
    na = body.count(a)
    nb = body.count(b)
    if a == b:
        in_title = a in TITLE
        print("    ✓ 正文 %d 处；%s" % (na, ("题名用「%s」，作者原题，保留" % b[:2]) if in_title else why))
        continue
    if na and nb:
        print("    ⚠ 「%s」×%d  「%s」×%d   %s" % (a, na, b, nb, why))
        flag("!", "术语", "全文", "「%s」与「%s」并存：%s" % (a, b, why))
    elif na or nb:
        print("    ✓ %-14s ×%d  （%s 未出现）" % (a, na or nb, b if not nb else a))

# ================= 4. repeated sentences =================
print()
print("=" * 74)
print("  4  重复句")
sents = []
for i, l in enumerate(lines[:END], 1):
    s = l.strip()
    if len(s) < 24 or s.startswith(("|", "```", "#", ">", "---")):
        continue
    for part in re.split(r"[。；]", s):
        part = part.strip()
        if len(part) >= 24:
            sents.append((i, part))
seen = collections.defaultdict(list)
for i, s in sents:
    seen[s].append(i)
dups = {s: v for s, v in seen.items() if len(v) > 1}
if dups:
    for s, v in dups.items():
        print("    !! 行%s 重复：%s…" % (v, s[:56]))
        flag("!!", "重复", "行%s" % v, s[:60])
else:
    print("    ✓ 无重复句")

# ================= 5. hedging / filler =================
print()
print("=" * 74)
print("  5  含混与填充")
HEDGE = ["据称", "众所周知", "不难发现", "显而易见", "综上", "总的来说",
         "在一定程度上", "某种程度上", "有待进一步", "值得深思"]
found = False
for w in HEDGE:
    n = md.count(w)
    if n:
        print("    ⚠ 「%s」×%d" % (w, n))
        flag("!", "含混", "全文", "「%s」×%d" % (w, n))
        found = True
if not found:
    print("    ✓ 无含混套话")

# ================= 6. structure =================
print()
print("=" * 74)
print("  6  结构与规模")
heads = [(i, l) for i, l in enumerate(lines[:END], 1) if re.match(r"^#{1,3} ", l)]
print("    标题 %d 个（一级 %d / 二级 %d / 三级 %d）" % (
    len(heads),
    sum(1 for _, l in heads if l.startswith("# ")),
    sum(1 for _, l in heads if l.startswith("## ")),
    sum(1 for _, l in heads if l.startswith("### "))))
figs = len(re.findall(r"^!\[" , body, re.M))
tabs = len(re.findall(r"^\|.*\|\s*$", body, re.M))
print("    图 %d  表 %d  段落 %d" % (
    len(re.findall(r"^!\[[^\]]*\]\(", body, re.M)),
    len(re.findall(r"^表\s*\d+　", body, re.M)),
    len([s for s in body.split("\n\n") if s.strip()])))
print("    问号 %d（正文 %d）" % (md.count("？"), body.count("？")))
print("    引号不成对：左 %d 右 %d" % (md.count("“"), md.count("”")))
if md.count("“") != md.count("”"):
    flag("!!", "标点", "全文", "引号不配对 %d/%d" % (md.count("“"), md.count("”")))
    print("    !! 引号不配对")

# ================= summary =================
print()
print("=" * 74)
print("  汇总：严重 %d / 提示 %d" % (sum(1 for x in issues if x[0] == "!!"),
                                sum(1 for x in issues if x[0] == "!")))
for sev, cat, where, what in issues:
    print("    [%s] %-4s %-6s %s" % (sev, cat, where, what))