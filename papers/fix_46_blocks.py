#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Convert the two data blocks in 4.6 into tables, and move the rest of the numbers out of prose.

The two blocks hold readings, not code: four rows of per-stream throughput and queueing, and four
rows of per-thread schedstat accounting. They were set as monospaced text, which is a terminal
convention and not a journal one -- guideline item 2 asks for tables with numbered captions and
English translations, and a reader cannot compare two rows of fixed-width text as easily as two
rows of a bordered table. Both are now tables, which also means the numbers stop being counted as
prose, since a number inside a table row has somewhere to be looked up.

Numbering follows the draft's existing rule, position-based, so the new tables take 9 and 10 and
nothing shifts. Table 9 is placed where the block was, immediately after the paragraph that reads
table 7, so a reader of table 7 is a reader of table 9.

The remaining prose numbers are the two corrections: the superseded accounting that made the ratio
3.11, and the two reproduction rounds whose wall clock is longer than the recorded window. Both
already point at the attachment, and both keep only the statement, since the figures they cite are
in the attachment and in table 9.
"""
import pathlib, re, sys

P = pathlib.Path("papers/论文-慢层只读一次原则.md")
md = P.read_text(encoding="utf-8")
orig = md

# ---- 1. block one: per-stream readings ----
b1_old = ("```\n"
          "主干流         708 – 1003 MB/s 每流，队列 0.1 s (0.1%)\n"
          "专家流         34 –  46 MB/s 每流，队列 57 – 76 s (3.1–4.2%)\n"
          "worker 睡眠    占墙钟 40 – 49%\n"
          "实际并发       8.9 – 10.0×（配置 16 个 worker）\n"
          "```")
b1_new = ("表 9　两条读取流的实测速率与运行队列（分档运行）\n"
          "Table 9　Measured rate and run-queue depth per stream, per tier allocation\n\n"
          "| 流 | 每流速率 | 运行队列 |\n"
          "| --- | --- | --- |\n"
          "| 主干流 | 708–1003 MB/s | 0.1 s（0.1%） |\n"
          "| 专家流 | 34–46 MB/s | 57–76 s（3.1–4.2%） |\n"
          "| worker 睡眠 | 占墙钟 40–49% | — |\n"
          "| 实际并发 | 8.9–10.0×（配置 16 个 worker） | — |")
if b1_old not in md:
    sys.exit("★ 未找到块一")
md = md.replace(b1_old, b1_new, 1)
print("  ✓ 块一 → 表 9")

# ---- 2. block two: schedstat accounting ----
b2_old = ("```\n"
          "线程                     在核          运行队列等待    等待/在核\n"
          "主线程（producer）        92.15 s         2.59 s       0.028\n"
          "16 个 kio worker      各 48 – 58 s   各 1.9 – 3.3 s   0.039 – 0.063\n"
          "另 4 个线程          各 23.2 – 23.5 s  约 2.5 s      0.105 – 0.111\n"
          "────────────────────────────────────────────────────────────\n"
          "合计（21/26 线程有增量） 1007.4 s       52.7 s        0.052\n"
          "```")
b2_new = ("表 10　按线程类别的内核记账（`schedstat` 采样，单位 s）\n"
          "Table 10　Kernel accounting by thread class (schedstat samples, seconds)\n\n"
          "| 线程类别 | 在核 | 运行队列等待 | 等待/在核 |\n"
          "| --- | --- | --- | --- |\n"
          "| 主线程（producer） | 92.15 | 2.59 | 0.028 |\n"
          "| 16 个 kio worker | 各 48–58 | 各 1.9–3.3 | 0.039–0.063 |\n"
          "| 另 4 个线程 | 各 23.2–23.5 | 约 2.5 | 0.105–0.111 |\n"
          "| **合计**（21/26 线程有增量） | **1007.4** | **52.7** | **0.052** |")
if b2_old not in md:
    sys.exit("★ 未找到块二")
md = md.replace(b2_old, b2_new, 1)
print("  ✓ 块二 → 表 10")

# ---- 3. the prose that read the blocks ----
PROSE = [
    ("上表两行的速率由时间派生，不可复现；字节量才可复现。后续两次复现把这一点摆了出来："
     "每词元的请求数与字节总量与本节完全相同，专家流每流速率却只有 30 与 29 MB/s，低于上表区间；"
     "主干流 833 与 745 MB/s，仍在区间内。两次复现的墙钟（98.90 与 104.66 s/词元）长于本节记录时段，"
     "字节除以更长的墙钟，自然得到更低的速率。**验收应核对字节而非速率；本文已记录的时间上界为 104.66 s/词元。** 完整数字见附件 A.1。",
     "表 9 前两行的速率由时间派生，不可复现；字节量才可复现。后续两次复现把这一点摆了出来："
     "每词元的请求数与字节总量与本节完全相同，专家流的每流速率却低于表 9 的区间，主干流仍在区间内；"
     "两次复现的墙钟长于本节记录时段，字节除以更长的墙钟，自然得到更低的速率。"
     "**验收应核对字节而非速率。** 两次复现的完整数字与本文记录的最慢一次墙钟见随稿附件 A.1。"),
    ("上表的并发倍数不是独立于睡眠占比的第二个量，二者同源：",
     "表 9 的并发倍数不是独立于睡眠占比的第二个量，二者同源："),
    ("判定为非 CPU 受限，三条依据：运行队列等待均远小于在核时间，而饱和时两者应当相当；"
     "在核总量折合 8 核中的 3.2 核，即 40% 占用；队列等待仅占可用核时的 2.1%。"
     "worker 在核仅占墙钟 16%，说明它们真正阻塞在 `cond_wait` 而非自旋。",
     "判定为非 CPU 受限，三条依据，都可从表 10 读出：运行队列等待均远小于在核时间，"
     "而饱和时两者应当相当；在核总量折合 8 核中的 3.2 核，即 40% 占用；"
     "队列等待仅占可用核时的 2.1%。worker 在核仅占墙钟 16%，说明它们真正阻塞在等待而非自旋。"),
]
for a, b in PROSE:
    if a not in md:
        print("  ★ 未匹配：%s…" % a[:40])
        sys.exit(1)
    md = md.replace(a, b, 1)
    print("  ✓ 正文改写：%s…" % b[:38])

P.write_text(md, encoding="utf-8")
print("  篇幅变化 %+d 字符" % (len(md) - len(orig)))

md2 = P.read_text(encoding="utf-8")
print()
print("  代码块剩余：%d" % md2.count("\n```"))
cn = [int(m) for m in re.findall(r"^表\s*(\d+)\u3000", md2, re.M)]
en = [int(m) for m in re.findall(r"^Table\s*(\d+)\u3000", md2, re.M)]
print("  表号 %s" % cn)
print("  英文 %s" % en)
print("  连续：%s" % (cn == en == list(range(1, len(cn) + 1))))