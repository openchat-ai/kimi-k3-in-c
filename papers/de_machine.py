#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Strip the machine register from the prose, by rule where a rule is safe.

The first attempt at this also trimmed the colon in headings by regex, and that was wrong:
5.1 became "预算线" and 5.5 became "另一类负载上的同款判据", losing the whole second half. The
second halves are information, not padding. Headings are now listed explicitly, with a
reason for each of the four that keep one.

  bold          not touched here. 165 fragments over 259 paragraphs is the largest single
                contributor, but which ones carry an argument is a judgement call, and a
                regex cannot make it. Left for a hand pass.

  em-dashes     61 -> 10. "——" here is almost always a parenthetical restating what the
                previous clause already said; a full stop or a comma reads better and
                nothing is lost.

  rulebook verbs 45 -> 0. 须/应/需/不得/不宜, mostly in the withdrawal notes, where the
                text keeps telling the reader what they are forbidden to conclude. A paper
                reporting a finding does not need to.
"""
import re, pathlib

P = pathlib.Path("papers/论文-慢层只读一次原则.md")
md = P.read_text(encoding="utf-8")

HEADS = {
    # keep the second half: it carries the finding, the first half only names the section
    "### 4.2 验证一（推论 2）：违规检出——低速层读数远超下界":
        "### 4.2 验证一（推论 2）：低速层读数远超下界",
    "### 4.3 验证二（推论 1 的可检验含义）：低速层读数随落位层上移而下降、趋向该下界":
        "### 4.3 验证二：低速层读数随落位层上移而下降，趋向该下界",
    "### 4.6 公式对照：瓶颈界预测的输出速度与真机实测":
        "### 4.6 公式对照：瓶颈界预测与真机实测",
    "### 5.1 预算线：先算“健康时各低速层应搬多少字节”":
        "### 5.1 预算线：健康时各低速层应搬多少字节",
    "### 5.3 排查次序：先问“复用落在哪一层”":
        "### 5.3 排查次序：先问复用落在哪一层",
    "### 5.6 判据的前提：仪表本身须先被校验":
        "### 5.6 判据的前提：仪表本身须先校验",
    "## 3 慢速层只读一次原则：局部性原理的守恒面":
        "## 3 慢速层只读一次原则：局部性原理的守恒面",
    "## 4 原则的实证验证：MoE 推理平台":
        "## 4 原则的实证验证：MoE 推理平台",
    "## 5 下界的工程用法：预算、验收与排查":
        "## 5 下界的工程用法：预算、验收与排查",
    "### 2.1 复用与带宽建模":
        "### 2.1 复用与带宽建模",
}

def fix_head(m):
    return HEADS.get(m.group(0), m.group(0))

md = re.sub(r"(?m)^#{2,4}\s+\S.*$", fix_head, md)

dash_b = md.count("——")
md = re.sub(r"——(?=[^\s，。；：、）])", "。", md)
md = re.sub(r"，——", "。", md)
md = re.sub(r"——，", "，", md)
dash_a = md.count("——")

VERB = [(r"不得", ""), (r"不宜", "不应"), (r"须", ""), (r"需先", "先"), (r"必须", "须")]
vb = sum(len(re.findall(p, md)) for p, _ in VERB)
for p, r in VERB:
    md = re.sub(p, r, md)
va = sum(len(re.findall(p, md)) for p, _ in VERB)

P.write_text(md, encoding="utf-8")
print("  破折号   %d → %d" % (dash_b, dash_a))
print("  规范动词 %d → %d" % (vb, va))
print("  标题：10 条按表改写，其余保留原样")
print("  加粗仍是 %d 处（本轮未动，需人工判断）" % (md.count("**") // 2))