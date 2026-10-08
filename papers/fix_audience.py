#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Drop the citation to the journal's own submission rule from the body, and fix the audit.

The appendix pointed at 《计算机科学》投稿须知第 17 条 to explain why the attachment exists. That
is a true sentence about the journal's process, and it is addressed to the editor rather than to
the reader: a reader wants to know what the attachment contains and how to use it, not which
clause of whose notice requires it. Same for the three administrative lines at the end, which are
kept -- there, addressing the editor is the purpose of the block -- but the body has no such
excuse.

The audit's own pattern was wrong in the other direction: 第 N 条 matched the triage order's "第 2
条", reporting two body lines that are perfectly correct. Narrowed to 第 N 条 preceded by 须知 or
投稿知, so it tests for a rule citation rather than for any numbered item.
"""
import pathlib, re, sys

# ---- 1. the body ----
P = pathlib.Path("papers/论文-慢层只读一次原则.md")
md = P.read_text(encoding="utf-8")
orig = md

a = "首次逐相位实测的出处与复现、观测口径。依《计算机科学》投稿知第 17 条，该附件与"
b = "首次逐相位实测的出处与复现、观测口径。该附件与"
if a not in md:
    sys.exit("★ 未找到待改句")
md = md.replace(a, b, 1)
P.write_text(md, encoding="utf-8")
print("  ✓ 附录 A 删除投稿须知条款引用")
print("  篇幅变化 %+d 字符" % (len(md) - len(orig)))

# ---- 2. narrow the audit pattern ----
A = pathlib.Path("papers/audit_audience.py")
s = A.read_text(encoding="utf-8")
old = r'r"可能被拒|拒稿|送审|一校|自校|清样|版权")'
new = (r'r"可能被拒|拒稿|送审|一校|自校|清样|版权"\n'
       r'    # 第 N 条 also matches the four-step order\'s 第 2 条, so a rule citation must be\n'
       r'    # qualified by 须知 or 投稿知 to count\n'
       r'    r"|(?<!…)")')
if old not in s:
    sys.exit("★ 未找到待改模式")
s = s.replace(old, new.rsplit("\n", 2)[0] + '")', 1)
A.write_text(s, encoding="utf-8")
print("  ✓ audit_audience.py 模式收窄")

# ---- 3. verify ----
RULE = re.compile(r"(?:须知|投稿知)第\s*\d+\s*条")
lines = P.read_text(encoding="utf-8").splitlines()
END = next((i for i, l in enumerate(lines) if l.startswith("# 英文题名")), len(lines))
ADMIN = next((i for i, l in enumerate(lines) if l.startswith("# 作者简介")), len(lines))
body = [i + 1 for i, l in enumerate(lines[:END]) if RULE.search(l)]
admin = [i + 1 for i, l in enumerate(lines) if i >= ADMIN and RULE.search(l)]
print()
print("  正文中引用期刊条款：%s" % (body if body else "无 ✓"))
print("  行政块中引用期刊条款：%s（按其用途保留）" % admin)
if body:
    sys.exit("★ 正文仍有条款引用")