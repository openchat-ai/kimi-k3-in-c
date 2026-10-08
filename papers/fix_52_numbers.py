#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Fold 5.2's numbers into tables, so the criterion section carries no figures the reader must hold.

5.2 reports twenty-five quantities with nothing in the section carrying them, and they are not a
long tail -- they are the same few measurements quoted again and again: 1.30-1.58 in four places,
2.7 in three, 1786 in three, the two wall clocks, the per-stream rates. A criterion section that
quotes a ratio four times is a section where the ratio is standing in for a table.

So the paired measurements become two tables. One holds the three interleaved pairs, device arm
against engine arm in the same window, which is where 1.30-1.58 comes from. The other holds the two
independent runs of the same continuous arm, 1786 against 1214, which is the measurement-quality
limit and the reason the ratio is reported as a range. The prose then says what each table shows and
quotes a figure only where the number itself is the claim -- the paired range in the conclusion, and
the 47% disagreement in the caveat.

The 2.7 stays where it is, in the line that asserts the direction and existence of the gap while
declining to quantify its size, because that sentence is about the difference between two numbers
and would lose its point without them.

The three overturned attributions keep their figures. They are not data reporting; each pair is
the thing that was believed and then refuted, and removing the numbers would leave three
assertions with nothing to refute.
"""
import pathlib, re, sys

P = pathlib.Path("papers/论文-慢层只读一次原则.md")
md = P.read_text(encoding="utf-8")
orig = md

# ---- 1. the paired measurements block -> table 11 ----
old1 = ("设备混合形态聚合  1222 / 1136 / 1367 MB/s\n"
        "引擎聚合（同一窗口）941 / 825 / 863 MB/s")
new1 = ("表 11　三对交错配对：设备臂与引擎臂同窗口交替（MB/s）\n"
        "Table 11　Three interleaved pairs, device arm against engine arm in the same window\n\n"
        "| 配对 | 设备混合形态聚合 | 引擎聚合 | 引擎/设备 |\n"
        "| --- | --- | --- | --- |\n"
        "| 1 | 1222 | 941 | 0.77 |\n"
        "| 2 | 1136 | 825 | 0.73 |\n"
        "| 3 | 1367 | 863 | 0.63 |\n"
        "| **配对差中位** | — | — | **1.30–1.58 倍** |")
if old1 not in md:
    sys.exit("★ 未找到配对块")
md = md.replace(old1, new1, 1)
print("  ✓ 配对块 → 表 11")

# ---- 2. the two continuous-arm runs -> table 12 ----
a2 = ("测量口径上的一个限制值得记录：同一连续臂在两轮独立测量间可相差 47%（1786 对 1214 MB/s），"
      "`v37_burst` 五个臂中四个按 IQR/中位数 超 0.15 判为噪声。**因此单次存储测量不足以支撑倍数结论**；"
      "上表的倍数由设备臂与引擎臂同窗口交替取得，代价是每对需 210 s 连续窗口。")
b2 = ("测量口径上有一处限制值得记录：同一连续臂在两轮独立测量间可相差 47%（表 12），"
      "而五个臂中四个按 IQR/中位数 超 0.15 判为噪声。**因此单次存储测量不足以支撑倍数结论**；"
      "表 11 的倍数由设备臂与引擎臂同窗口交替取得，代价是每对需 210 s 连续窗口。\n\n"
      "表 12　同一连续臂的两轮独立测量（MB/s）\n"
      "Table 12　Two independent measurements of the same continuous arm\n\n"
      "| 轮次 | 读数 | 相对偏差 |\n"
      "| --- | --- | --- |\n"
      "| 第 1 轮 | 1786 | — |\n"
      "| 第 2 轮 | 1214 | **−47%** |")
if a2 not in md:
    sys.exit("★ 未找到口径限制段")
md = md.replace(a2, b2, 1)
print("  ✓ 口径限制 → 表 12")

# ---- 3. prose that now points at the tables ----
PROSE = [
    ("**未能定量的部分。** 引擎在 16 并发下的聚合速率为 379 MB/s（表 5，n=3 中位数），"
     "而**同盘、同单元、同 O_DIRECT、同 16 并发的独立测量给出 1100–1800 MB/s**（随稿附件 A.4.2）。"
     "**二者相差至少 2.7 倍，差距的方向与存在性成立；幅度不可定量**，理由如下。",
     "**未能定量的部分。** 引擎在 16 并发下的聚合速率为 379 MB/s（表 5），"
     "而**同盘、同单元、同 O_DIRECT、同 16 并发的独立测量高出数倍**（表 11、随稿附件 A.4.2）。"
     "**二者相差至少 2.7 倍，差距的方向与存在性成立；幅度不可定量**，理由如下。"),
    ("该差距以同盘、同单元（`l2.slot_bytes` = 17547264）、O_DIRECT、主干顺序流与专家散乱流同盘并发、"
     "210 s 连续、3 对交错配对测得（随稿附件 A.4.2）：",
     "该差距以同盘、同单元（`l2.slot_bytes` = 17547264）、O_DIRECT、主干顺序流与专家散乱流同盘并发、"
     "210 s 连续、3 对交错配对测得（表 11）："),
    ("差距的方向与存在性不受测量口径影响，幅度则随口径变化：由三对交错配对测得 1.30–1.58 倍。"
     "以 buffered 读与错误单元尺寸得到的速率不满足与引擎同口径",
     "差距的方向与存在性不受测量口径影响，幅度则随口径变化：由三对交错配对测得 1.30–1.58 倍（表 11）。"
     "以 buffered 读与错误单元尺寸得到的速率不满足与引擎同口径"),
    ("**因此本节的结论是：差距存在，为 1.30–1.58 倍，机制已在引擎内定位为算术与 I/O 串行化（§4.6）。**",
     "**因此本节的结论是：差距存在，为 1.30–1.58 倍（表 11），机制已在引擎内定位为算术与 I/O 串行化（§4.6）。**"),
]
for a, b in PROSE:
    if a not in md:
        print("  ★ 未匹配：%s…" % a[:44])
        sys.exit(1)
    md = md.replace(a, b, 1)
    print("  ✓ 正文改写：%s…" % b[:40])

P.write_text(md, encoding="utf-8")
print("  篇幅变化 %+d 字符" % (len(md) - len(orig)))

md2 = P.read_text(encoding="utf-8")
cn = [int(m) for m in re.findall(r"^表\s*(\d+)\u3000", md2, re.M)]
en = [int(m) for m in re.findall(r"^Table\s*(\d+)\u3000", md2, re.M)]
print("  表号 %s" % cn)
print("  连续且中英对应：%s" % (cn == en == list(range(1, len(cn) + 1))))