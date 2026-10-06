#!/bin/bash
# Add the decision rule to BENCH_PROTO itself. It currently lives in FINDINGS.md and in the
# paper, but the protocol file is what anyone actually follows before running something, and
# thirteen experiments were run under an 11.6% band that describes only the six runs it came
# from. Appended rather than edited so the existing sections keep their numbering.
set -u
P=/mnt/f/kimi-k3-in-c/reports/gateab_ab/BENCH_PROTO.md
if grep -q "^## 14\." "$P"; then echo "section 14 already present, not appending again"; exit 0; fi

cat >> "$P" <<'EOF'

## 14. 判定门槛：先证明测得出，再去测

13.1–13.6 讲的是怎么让探针不说谎。本节讲的是**该不该做这次测量**。

**问题的来源。** 2026-09-29 至 10-05 期间做了 19 次端到端 `s/词元` 运行，
用来判定若干 1–7% 的配置差异。同一份源码、同一脚本、连续三轮给出 65.21 / 75.62 / 79.91
s/词元，跨度 22.5%；19 次合并跨度 65.21–89.88。而被比较的差异是 1–7%。
**结论连续翻转，不是系统难懂，是实验功效不足。**

**没有轮数能修好这件事。** 22–31% 的噪声对 1–7% 的效应，轮数再多、统计再强，
效应量仍落在噪声里。**唯一的解法是换观测量或换设计**，不是加样本。

```规则：立项前先算"测得出吗"——
      目标效应 ÷ 观测量噪声 ≥ 3 才值得立项；
      比值 < 3 就不要跑，因为跑多少轮都判不出来。

      对 s/词元 类观测量，本平台实测噪声 22–31%（两个时段分别 22.5% 与 3.6%，
      故不得引用单一时段），因此任何 <10% 的配置间差异一律不可判定。

      判定"有差异"必须同时满足：
        (1) 同一时段内交错配对重复 ≥5 轮
        (2) 配对差 ≥10%
      任一不满足即记为"无差异"，不再加轮。

      不得引用跨时段的绝对速率作对比。
```

**优先选不会动的观测量。** 本次唯一在 10 轮、跨两版代码下稳定的量是：
每流速率、队列时长、每词元请求数与字节数、worker 睡眠占墙钟比、实际并发倍数。
这些量在 19 次运行里几乎不动，而 `s/词元` 跨了 22–31%。
**字节计数尤其可靠——论文第 4.2、4.3 节的实证核心正是以字节核算，
因此完全不受本节影响。**

**反例留档。** 一次二分定位 10-01 三个提交的"退化"，四点为
83.60 / 84.63 / 86.70 / 89.88 s/词元，看着单调、逐步 1–4%。
但其中第一点是我的提交、同一份源码，早前测得 65.21。
**单调斜率在噪声里毫无意义**，该"退化"至今未被证实，也未被排除。
EOF
echo "appended section 14; file is now $(wc -l < "$P") lines"