#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Repoint the six references the renumbering pass corrupted, by what each table holds.

Renumbering builds its old-to-new map from caption numbers, and after two tables were added in
one pass a number appeared on two captions, so the map sent references to the wrong table -- the
same defect as the first time, and the guard against it has to be content, not arithmetic.

Table numbers in document order: 1 six bad counters, 2 derived quantities and their cross-checks,
3 expert-stage baseline ledger, 4 bytes per tier as the landing tier rises, 5 the phase-resolved
table, 6 replacement policy on the byte account, 7 formula against measurement, 8 per-stream rate and
run queue, 9 kernel accounting by thread class, 10 the three interleaved pairs, 11 the two
independent runs of one arm, 12 the four-step replay.

The six references, and what each points at:

  table 12 前两行          -> 8   the two stream rows whose rates are derived from time
  below table 12's range   -> 8
  table 12's concurrency   -> 8
  1.30-1.58 倍            -> 10  the interleaved pairs
  47%                    -> 11  the two runs of one arm
  table 11's multiples    -> 10
"""
import pathlib, sys

P = pathlib.Path("papers/论文-慢层只读一次原则.md")
lines = P.read_text(encoding="utf-8").splitlines()

FIX = [
    (278, "表 12 前两行的速率由时间派生", "表 8 前两行的速率由时间派生"),
    (278, "专家流的每流速率却低于表 12 的区间", "专家流的每流速率却低于表 8 的区间"),
    (280, "表 12 的并发倍数不是独立于", "表 8 的并发倍数不是独立于"),
    (385, "1.30–1.58 倍（表 12）", "1.30–1.58 倍（表 10）"),
    (389, "可相差 47%（表 12）", "可相差 47%（表 11）"),
    (389, "表 12 的倍数由设备臂", "表 10 的倍数由设备臂"),
    (399, "1.30–1.58 倍（表 12）", "1.30–1.58 倍（表 10）"),
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
print("  已写入")