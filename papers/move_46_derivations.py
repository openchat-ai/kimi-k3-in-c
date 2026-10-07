#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Move section 4.6's derivations out of the paper and into the attachment.

The author decided to delete rather than keep the derivations, but "delete" here means move:
the reasoning behind each of the four revisions is the answer to "how do you know", and
throwing it away would leave a reviewer who computes something that disagrees with table 4
with nothing to point at. So the text goes to the attachment, which 投稿须知 item 17 already
requires, and the paper keeps the conclusions, the dates, and the pointer.

What stays in the paper:
  - the reading guide, because a reader looking at table 4 needs it in front of them
  - four dated one-line entries: what changed, not how it was found
  - the schedstat verdict, compressed from a seven-row table to its conclusion
  - the byte/timing observability split, which is a finding rather than a derivation
  - the methodological limit, since it bounds every number in the section

What goes to the attachment:
  - how the 09-29 rebuild found the 453 MB/s single-stream error and the time-sum overlap
  - the denominator error in detail, and the interleaved re-measurement parameters
  - the 判带 correction note about the pre-registered bands
  - the v54 attribution withdrawal in full, including the survival-21% caveat
  - the byte and bandwidth provenance list
"""
import pathlib, re, sys

PAPER = pathlib.Path("papers/论文-慢层只读一次原则.md")
ATT = pathlib.Path("papers/实验复现数据及环境配置说明.md")

md = PAPER.read_text(encoding="utf-8")
att = ATT.read_text(encoding="utf-8")

# ---- 1. pull the two paragraphs the attachment does not yet have ----
m_v54 = re.search(r"(?m)^\*\*同时撤回本节此前据 v54.*?ANALYSIS\.txt`。\s*$", md, re.S)
m_prov = re.search(r"(?m)^字节与带宽出处：.*?两者不可混用。\*\*\s*$", md, re.S)
if not m_v54:
    sys.exit("FATAL: 未找到 v54 撤回段，中止")
if not m_prov:
    sys.exit("FATAL: 未找到字节与带宽出处段，中止")

v54 = m_v54.group(0).strip()
prov = m_prov.group(0).strip()

BLOCK = """
### A.4 正文 4.6 节移出的推导（2026-10-07）

以下四段推理过程随稿保留于此，正文仅留结论与日期戳。若审稿人独立计算的结果与表 4
不一致，对应的发现过程在此。

#### A.4.1 2026-09-29 重建的发现过程

原表把 16 路并发的专家聚合速率按单流计（453 MB/s），且把重叠的时长相加当作暴露时间；
改为并集与互斥口径后，专家聚合速率 379 MB/s 与暴露 59.39 s 自洽，公式下限亦随之从
47.6 s 修正为 70.4 s。`k3_trace_token()` 当时从未在解码循环中被调用，`trace.csv` 的
`token` 列恒为 0，"扣除首词元冷启动后的稳态"无从测起；该函数已补（`v32_table2b/rep1..3`），
`token` 列现为 0–7 均匀分布。时长相加会重复计入 457.80 s，该值恰等于专家读并集。

#### A.4.2 2026-10-05 分母错误的发现过程

该比值的 W_i 取自引擎自身已实现的速率（主干 890 / 专家 379 MB/s），而公式 B_i/W_i 中的
W_i 按正文 4.6 节开头定义是设备可用带宽。以前者为分母，比值必然向 1 收敛，与设备是否
还有余量无关。重测以引擎的真实访问形态进行：同文件、O_DIRECT、主干顺序流与专家散乱流
**同盘并发**，210 s 连续，3 对交错配对（`v58_mix/ratios.txt`）。

#### A.4.3 2026-10-07 判定带的一处修正

schedstat 探针预设的判定带把比值 0.02–0.20 定为"两者兼有"，实测 0.052 落入该带。
该带未与物理参照挂钩——饱和意味着比值 ≥ 1，0.052 明显偏于不受限一侧，且绝对占用
（8 核中 3.2 核 = 40%）才是决定量。原始件与预设带均保留
（`reports/gateab_ab/v64_schedstat/`、`v64_probe_attempt1.out`），判定按绝对量重做。

#### A.4.4 v54 归因撤回

"""

BLOCK2 = """
#### A.4.5 表 4 各档字节与带宽的出处

"""
BLOCK2 += prov + "\n"

BLOCK3 = "\n" + v54 + "\n"

if "A.4 正文 4.6 节移出的推导" not in att:
    att = att.rstrip() + "\n\n" + BLOCK + BLOCK2 + BLOCK3
    ATT.write_text(att, encoding="utf-8")

# ---- 2. the one-line replacement in the paper ----
OLD_V54 = m_v54.group(0)
OLD_PROV = m_prov.group(0)

REPL_V54 = ("**【2026-10-05 撤回】** 本节此前据 v54 写入的\"主干顺序流与专家散乱流在同一设备上"
            "互相争抢\"不成立：散乱 4M 读（1740 MB/s）快于顺序（1537 MB/s）。该次观测到的 arena "
            "扩大导致 trunk 常驻由 22 层降至 15 层、75.5→126.2 s/词元，这一现象成立，机制尚未查明。"
            "发现过程见附件 A.4.4。\n")

REPL_PROV = ("表 4 各档的字节与带宽出处见附件 A.4.5。\n")

md = md.replace(OLD_V54, REPL_V54).replace(OLD_PROV, REPL_PROV)

PAPER.write_text(md, encoding="utf-8")

print("  移出 2 段：v54 撤回 %d 字，字节与带宽出处 %d 字" % (len(v54), len(prov)))
print("  正文改为 %d 字 + %d 字" % (len(REPL_V54.strip()), len(REPL_PROV.strip())))
print("  附件新增 A.4 四小节，共 %d 字" % (len(BLOCK) + len(BLOCK2) + len(BLOCK3)))