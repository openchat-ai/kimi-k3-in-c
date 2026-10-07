#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""What connective variety does the paper actually have?

The criticism is that the prose leans on a narrow set of connectors -- 故/因此/由此/据此 --
where human writing varies: 虽然, 但是, 然后, 排比, 反问, and short declaratives. Count
them rather than argue about it.
"""
import re, pathlib, collections

md = pathlib.Path("papers/论文-慢层只读一次原则.md").read_text(encoding="utf-8")
lines = [l for l in md.splitlines() if l.strip() and not l.strip().startswith(("|", "```", "#"))]

GROUPS = {
    "因果：故/因此/由此/据此/因而": r"故|因此|由此|据此|因而|所以",
    "转折：虽然/但是/然而/却":       r"虽然|但是|然而|不过|而[^适]",
    "顺承：然后/接着/随后/再/又":      r"然后|接着|随后|继而|再[^不]",
    "选择：或/还是/要么":              r"或者|还是|要么",
    "语气：呢/吧/啊（口语）":           r"[呢吧啊](?![一-鿿])",
    "反问：难道/岂/何以/不也":          r"难道|岂不|何以|不也",
    "假设：若/如果/假如":              r"如果|假如|倘若|[^其]若",
    "程度：甚至/尤其/恰恰/恰恰是":      r"甚至|尤其|恰恰|正��",
    "弱化：可能/也许/大概":            r"可能|也许|大概|似乎|或许",
    "确认：确实/的确/显然/可见":       r"确实|的确|显然|可见|可见",
}
print("  连接词族计数（正文 %d 行）" % len(lines))
for name, pat in GROUPS.items():
    n = sum(len(re.findall(pat, l)) for l in lines)
    print("    %-26s %4d" % (name, n))

print()
# 排比: three or more same-structure items in one sentence
par = 0
for l in lines:
    for s in re.split(r"[。；]", l):
        if len(re.findall(r"[，、]", s)) >= 3 and len(s) > 40:
            par += 1
            break
print("  含三项以上并列的句子   %d" % par)

# 短陈述句
sents = [s.strip() for s in re.split(r"[。；]", "\n".join(lines)) if len(s.strip()) > 3]
L = sorted(len(s) for s in sents)
short = sum(1 for x in L if x < 25)
print("  句子总数 %d，短句(<25字) %d，占 %.0f%%" % (len(L), short, 100.0 * short / len(L)))
print("  中位句长 %d，P90 %d" % (L[len(L) // 2], L[int(len(L) * 0.9)]))

print()
print("  问号出现：%d 处" % "\n".join(lines).count("？"))
print("  省略号出现：%d 处" % "\n".join(lines).count("……"))
print()
print("  「但」作为转折词单独出现：%d 处" % sum(len(re.findall(r"，但", l)) for l in lines))
print("  「而」作为转折：%d 处" % sum(len(re.findall(r"，而", l)) for l in lines))
print("  「其实」/「倒也」/「不过」：%d 处" % sum(
    len(re.findall(r"其实|倒也|不过", l)) for l in lines))