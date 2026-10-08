#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Move the last of 4.6's prose numbers: the superseded accounting, and the two conclusions
that were wrong before a counter was fixed.

The two data blocks in 4.6 were readings, not code -- four rows of per-stream throughput and
queueing, four rows of per-thread schedstat accounting. They were set as monospaced text, which is
a terminal convention rather than a journal one: guideline item 2 asks for tables with numbered
captions and English translations, and two rows of fixed-width text are harder to compare than two
rows of a bordered table. Both are tables now, numbered 9 and 10, and the prose that read them
points at them.

That left ten numbers in prose. They fall into three groups:

  superseded    453 MB/s and 47.6 s are the per-flow and lower-bound figures that the original
                accounting produced before the overlap was fixed. They are kept, because naming the
                wrong value is how the correction is legible, but they now sit with the correction
                rather than being quoted again later.
  the fix       1740 and 1537 are what hit_wall and pread_seconds reported before and after. This
                is the instrument defect the whole cross-validation rule exists to catch, and the
                pair is the clearest possible statement of why: a derived quantity read zero while
                the quantity it derives from read 1740 s in the same log. The prose keeps the
                claim and the two numbers, because this is the one place the rule is demonstrated
                rather than asserted.
  elsewhere     the shape comparison's 17.5 MB and 1500 MB/s, and the method caveat's repeat
                figures, are already in the attachment and in figure 3.
"""
import pathlib, sys

P = pathlib.Path("papers/论文-慢层只读一次原则.md")
md = P.read_text(encoding="utf-8")
orig = md

FIX = [
    # superseded accounting: keep the wrong values, they are what makes the correction legible
    ("其一，**1.06 是计价口径修正的结果，不是设备变快。** 原表把 16 路并发的专家聚合速率按单流计"
     "（453 MB/s），并把重叠的时长相加当作暴露时间；改为并集与互斥口径后，公式下限从 47.6 s 修正为 "
     "70.4 s，比值随之由 3.11 降至 1.06。发现过程见附件 A.4.1。",
     "其一，**1.06 是计价口径修正的结果，不是设备变快。** 原表把 16 路并发的专家聚合速率按单流计，"
     "并把重叠的时长相加当作暴露时间；改为并集与互斥口径后，比值随之由 3.11 降至 1.06。"
     "修正前后的两组数值见随稿附件 A.4.1。"),
]
for a, b in FIX:
    if a not in md:
        print("  ★ 未匹配：%s…" % a[:44])
        sys.exit(1)
    md = md.replace(a, b, 1)
    print("  ✓ %s…" % b[:40])

P.write_text(md, encoding="utf-8")
print("  篇幅变化 %+d 字符" % (len(md) - len(orig)))
md2 = P.read_text(encoding="utf-8")
print("  「453」%d  「47.6」%d（表 9、10 已建，其余按附件处理）"
      % (md2.count("453"), md2.count("47.6")))