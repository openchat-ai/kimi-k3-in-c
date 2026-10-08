#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Repoint the two references left in 5.2, and restore check_table_refs.py's name list."""
import pathlib, sys

# ---- 1. the two remaining wrong references ----
P = pathlib.Path("papers/论文-慢层只读一次原则.md")
lines = P.read_text(encoding="utf-8").splitlines()
FIX = [
    (368, "（表 12、随稿附件 A.4.2）", "（表 10、随稿附件 A.4.2）"),
    (370, "（表 12）", "（表 10）"),
]
fail = []
for ln, old, new in FIX:
    s = lines[ln - 1]
    if old not in s:
        fail.append((ln, old))
        continue
    lines[ln - 1] = s.replace(old, new, 1)
    print("  ✓ 行%-4d %s" % (ln, new))
if fail:
    for ln, o in fail:
        print("  ★ 行%d 未匹配：%s" % (ln, o))
    sys.exit("★ 未写入")
P.write_text("\n".join(lines) + "\n", encoding="utf-8")

# ---- 2. restore the checker's name list ----
A = pathlib.Path("papers/check_table_refs.py")
s = A.read_text(encoding="utf-8")
bad = ('"表 12、随稿附件 A.4.2）" → that one is "表 12、随稿附件" on lines 368/370, which should be 表 10.\n\n'
       'Let me handle those two by pattern.')
good = ('by_name = any(w in ctx for w in ("目标档", "该行", "两行", "各档", "同一数据",\n'
        '                                         "末行", "各层", "一行", "同源", "见表",\n'
        '                                         "见上表", "表注", "两档数值", "从表",\n'
        '                                         "前两行", "读出", "区间", "几乎占满",\n'
        '                                         "近乎免费", "对照", "取值", "倍数"))')
if bad not in s:
    print("  ★ 检查器未处于预期状态")
    sys.exit(1)
A.write_text(s.replace(bad, good, 1), encoding="utf-8")
print("  ✓ check_table_refs.py 名称表已恢复")