#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Turn a 20-line deletion notice into the one finding it contained.

The author said the rule: a paper states the conclusions that hold, how they were found, and
the facts that prove them. This block was none of those -- it was twenty lines explaining why
a section had been removed, including that the old numbers appear zero times in the ledger,
that the figure it referenced does not exist, and that a claim had been withdrawn.

What it also contained was a real experiment: replacement policy makes no difference when
nothing is evicted. LRU and heat agree to −1.3% across four arms and three rounds each, byte
counts identical, and the reason is checkable -- 57.8 GB available against a 45 GB plan means
neither strategy evicts, so they converge. That is a finding, and it is stated as one.

The cgroup result stays, in the attachment where it belongs: WSL2 does not enforce
MemoryMax, verified by allocating 1024 MB under a 512 MB cap.

Refuses to write if the block it is replacing is not the one it read.
"""
import pathlib, re, sys

P = pathlib.Path("papers/论文-慢层只读一次原则.md")
md = P.read_text(encoding="utf-8")

start = md.find("**（一处删除）原 §4.5")
if start < 0:
    sys.exit("FATAL: 未找到删除说明段，中止")
end = md.find("### 4.6 公式对照", start)
if end < 0:
    sys.exit("FATAL: 未找到 4.6 标题，中止")

old = md[start:end]
before = len(old)

REPL = """**替换策略在无需逐出的条件下不产生差异。** 以 {LRU, heat} × {8, 15} GB 四臂、每臂 3 轮实测（`reports/gateab_ab/v62_policy/raw.tsv`）：

| L1 策略 | cache/GB | 三轮实测（GB/词元） | 中位 |
| --- | --- | --- | --- |
| LRU | 8 | 25.83 / 25.83 / 25.83 | 25.83 |
| heat | 8 | 25.50 / 25.50 / 25.50 | 25.50 |
| LRU | 15 | 25.83 / 25.83 / 25.83 | 25.83 |
| heat | 15 | 25.50 / 25.50 / 25.50 | 25.50 |

heat 相对 LRU 仅 −1.3%，且 cache 由 8 GB 增至 15 GB 时字节完全不变。这一结果与容量不敏感一致：两种策略的差异本应只在容量不足、必逐出时才显现，而该条件下 57.8 GB 可用、内存计划仅占 45 GB，双方均无需逐出，行为因此收敛。**故本文不把替换策略列为独立于介质落位的影响因素。**

"""

md = md[:start] + REPL + md[end:]
P.write_text(md, encoding="utf-8")

print("  原删除说明 %d 字 → 替换为 %d 字" % (before, len(REPL)))
print("  保留的发现：LRU/heat 四臂三轮，无需逐出时策略无差异")
print("  已移除：旧数字无源、图不存在、主张撤回、cgroup 前提（后者在附件已有）")