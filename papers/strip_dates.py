#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Replace revision dates in the paper with experiment ids or ordinals.

【2026-10-05 修正】 is changelog notation. It tells the reader when the author edited the
file, which is not a fact about the experiment. What the reader needs to know is which run
produced the number and in what order the corrections happened, so the dates go and the
experiment ids and ordinals come in:

  【2026-09-29 重建】      -> 末行（第二次逐相位实测）重建
  【2026-10-05 修正】      -> 第二次修正
  【2026-10-05 撤回】      -> 第三次修正
  【2026-10-05 删除】      -> 原"替换策略观测"一节已删除
  2026-09-28 原表          -> 首次逐相位实测的原表
  2026-10-07 判定          -> 第四次修正（判定）

Two kinds of date stay, because they are facts about the measurement rather than about the
editing: "冷启动 2026-08" describes when the data was collected, and the platform is stated
that way in the attachment. Both are handled explicitly rather than by a blanket rule, since a
blanket rule would strip those too.
"""
import re, pathlib, sys

P = pathlib.Path("papers/论文-慢层只读一次原则.md")
md = P.read_text(encoding="utf-8")
orig = md

EXACT = [
    # revision markers -> ordinals
    ("【2026-09-29 重建】", "（第二次逐相位实测）重建"),
    ("【2026-10-05 修正，本节结论改写】", "（第二次修正）"),
    ("【2026-10-05 补充第三条口径，2026-10-07 归因已判定】", "（第三次口径补充，归因经第四次修正判定）"),
    ("【2026-10-05 撤回】", "（第三次撤回）"),
    ("【2026-10-05 删除】", "（一处删除）"),
    ("【2026-10-05 更新】", "（第二次更新）"),
    # inline date references -> ordinals
    ("2026-09-28 原表的差异", "首次逐相位实测原表的差异"),
    ("2026-09-28 逐相位实测", "首次逐相位实测"),
    ("2026-10-07 的两次复现", "后续两次复现"),
    ("成因已于 2026-10-07 判定", "成因随后经直接测量判定"),
    ("2026-09-29 的三次（表 3", "同一档较早时段的���次（表 3"),
    ("表 3　2026-09-29 重建：", "表 3　第二次逐相位实测重建："),
]
for a, b in EXACT:
    if a not in md:
        print("  未找到（跳过）: %s" % a)
    md = md.replace(a, b)

# table row labels: identify the run, not the day
md = md.replace("| 今日最优（2026-09-24） |", "| 当日最优配置（首轮扫描） |")
md = md.replace("| 分相位实测（2026-09-29，主干常驻档，n=3 中位数） |",
                "| 分相位实测（第二次，主干常驻档，n=3 中位数） |")

# the English abstract names a date too
md = md.replace("A per-phase timeline measurement (2026-10-07)", "A per-phase timeline measurement (first run)")

left = re.findall(r"20\d\d-\d\d-\d\d", md)
P.write_text(md, encoding="utf-8")

print()
if left:
    print("  仍有 %d 处日期：" % len(left))
    for d in sorted(set(left)):
        n = md.count(d)
        print("    %s ×%d" % (d, n))
else:
    print("  已无 YYYY-MM-DD 形式的日期")

print("  保留的日期描述：", end="")
for m in re.finditer(r".{0,14}20\d\d-\d\d(?!-).{0,10}", md):
    print(" %r" % m.group(0).replace("\n", " "), end="")
print()