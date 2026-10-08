#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Rewrite the abstract in both languages from the finding outward.

The old abstract opened with the principle's derivation properties -- two explicit assumptions, no
hidden lemma, therefore checkable without consulting literature -- then a sentence about whether
the criterion is deep, then the platform, then the finding, then the four steps by name, then the
instrumentation rule defended at length, then a fragment beginning 因为, then a load-balancing
aside. Three papers compressed into one paragraph, and a reader who reached the third sentence no
longer knew what the paper was about.

The rewrite starts where the paper's subject is: a system at maximum hit rate that is not faster,
and what the bytes say instead. It then states the criterion and the rule, in that order, because
the rule is what makes the criterion usable. Everything about the principle's shallowness, the
derivation's properties, the four step names, the KV replay and the serialisation fragment is gone
from the abstract; all of it is in the body, where it belongs.

Three constraints shaped the wording. The template forbids first person in the abstract, and
verify_docx.py counts 本文 as first person, so the abstract carries no 本文 at all. The minimum is
300 Chinese characters and 300 English words, and both are met without padding: what fills the
count is the finding and the method, not qualification. And the platform is named before any
result is given, since a number whose subject is unnamed cannot be checked.
"""
import pathlib, re, sys

P = pathlib.Path("papers/论文-慢层只读一次原则.md")
lines = P.read_text(encoding="utf-8").splitlines()

CN = (
    "缓存命中率调至满格（CACHE HIT 100%），端到端吞吐仍达不到应有水平——"
    "这一现象出现在 Kimi K3（2.8T MoE）于存储受限主机上的冷启动推理中。"
    "按字节记账而非按命中率汇报，得到的是另一幅图景：每词元从低速盘全量重读专家权重 25.83 GB，"
    "占专家段端到端耗时的 94%；把专家权重迁至高速盘后，命中率仍是满格，每词元搬运量仍是 25.83 GB，"
    "一个字节未省。**命中只换了介质，没有免掉字节。**"
    "命中率统计的是介质命中与否，字节台账统计的是搬了多少字节——两者不是同一本账。"
    "**据此给出以字节为口径的验收判据**：按 distinct 集核算每层驻留预算，"
    "以低速层读数是否回落至下界判定复用是否落位，取代命中率白板；"
    "配套四条排查次序，每步标明读哪个计数器、什么算通过。"
    "判据以计数器为输入，而计数器会骗人，故另给一条与负载无关的规程："
    "凡派生量必须与一个独立的量交叉校验，并在报告中与被校量同屏打印。"
    "本轮六个曾产生错误结论的计数器字段全部由此发现，失效方式互不相同，"
    "共同点是误差与真实故障同量级，因而不会自我报警。"
    "全部数字取自单一平台、单一冷启动时序。**结论随字节账成立，不随速度账成立**："
    "同一配置连续 30 次运行的字节量完全相同，输出速度跨度却达 80.8%。"
)

EN = (
    "Cache hit rate at maximum (CACHE HIT 100%) while end-to-end throughput stays below its "
    "expected level \\u2014 this is what Kimi K3 (2.8T MoE) does at cold start on a "
    "memory-constrained host. Accounting in bytes rather than in hit rate gives a different "
    "picture: 25.83 GB of expert weights are re-read in full from the slow disk per token, which "
    "is 94% of that stage's end-to-end time, and moving the experts to a fast disk leaves the hit "
    "rate at maximum and the byte count at 25.83 GB per token, not one byte saved. A hit changes "
    "the tier the bytes come from; it does not remove them. Hit rate counts whether the media were "
    "hit, a byte ledger counts how many bytes moved, and those are two different books. "
    "**From that follows an acceptance criterion stated in bytes**: budget each tier by its "
    "distinct set, judge whether reuse has landed by whether the slow-tier read falls to its "
    "bound, and drop the hit-rate dashboard. Four diagnostic steps come with it, each naming which "
    "counter to read and what counts as passing. The criterion takes counters as input, and "
    "counters lie, so a second rule follows, independent of the workload: every derived quantity "
    "must be cross-checked against an independent quantity and printed beside it. Six counter "
    "fields that produced wrong conclusions in this run were all found that way; their failures "
    "are unrelated to one another and share one property, that the error is the same size as the "
    "real fault and therefore never raises an alarm. "
    "All figures come from one platform and one cold-start sequence. "
    "**The conclusion holds on the byte account and not on the speed account**: across thirty "
    "identical runs the byte count is identical while the output speed spans 80.8%, which is why "
    "a throughput threshold of the order of ten percent cannot be used to accept or reject a "
    "change in this setting. Where the four steps all pass and a gap remains, the gap is not in "
    "the reuse layer, and the search moves to achievable aggregate bandwidth."
).encode().decode("unicode_escape")

done_c = done_e = False
for i, l in enumerate(lines):
    s = l.strip()
    # the Chinese abstract is the paragraph between "## 摘要" and the keyword line; identify it
    # by position rather than by its opening words, which the previous rewrite changed
    if not done_c and "**关键词：**" not in s and len(s) > 200 \
            and not s.startswith("#") and not s.startswith("**"):
        lines[i] = CN
        done_c = True
        print("  ✓ 中文摘要已替换（原 %d 字 → 新 %d 汉字）"
              % (len(l), len(re.findall(r"[\u4e00-\u9fff]", CN))))
        continue
    if not done_e and s.startswith("**Abstract:**"):
        lines[i] = "**Abstract:** " + EN
        done_e = True
        print("  ✓ 英文摘要已替换（新 %d 词）"
              % len([w for w in EN.split() if re.search(r"[A-Za-z]", w)]))
        break

if not (done_c and done_e):
    sys.exit("★ 未替换：cn=%s en=%s" % (done_c, done_e))

P.write_text("\n".join(lines) + "\n", encoding="utf-8")

md = "\n".join(lines)
n_cjk = len(re.findall(r"[\u4e00-\u9fff]", CN))
n_en = len([w for w in EN.split() if re.search(r"[A-Za-z]", w)])
print()
print("  中文摘要 %d 汉字（模板 ≥300）%s" % (n_cjk, "✓" if n_cjk >= 300 else "★"))
print("  英文摘要 %d 词（模板 ≥300）%s" % (n_en, "✓" if n_en >= 300 else "★"))
for w in ("本文", "我们", "笔者"):
    in_cn = CN.count(w)
    in_en = EN.count(w)
    print("  第一人称「%s」中 %d / 英 %d %s"
          % (w, in_cn, in_en, "✓" if in_cn + in_en == 0 else "★"))
if n_cjk < 300 or n_en < 300:
    sys.exit("★ 字数不足")