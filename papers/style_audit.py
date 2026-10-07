#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Count the patterns that make the text read as machine-written.

Nothing here is a judgement call: each pattern is counted, so the criticism can be aimed at
the actual offenders rather than fixed by general fiddling.
"""
import re, pathlib, collections

p = pathlib.Path("papers/论文-慢层只读一次原则.md")
lines = p.read_text(encoding="utf-8").splitlines()

body = [l for l in lines if l.strip() and not l.strip().startswith("|")
        and not l.strip().startswith("```") and not l.strip().startswith("- ")]

# bold runs, and paragraphs whose LAST non-space char is inside a ** ... **
paras = [l.strip() for l in lines if l.strip() and not l.strip().startswith(("|", "```"))]
bold_tail = [l for l in paras if l.rstrip().endswith("**")]
bold_total = sum(l.count("**") for l in paras) // 2

print("  段落总数（不含表格/代码）  %d" % len(paras))
print("  加粗片段总数                %d" % bold_total)
print("  以加粗句收尾的段落          %d  （占 %.0f%%）"
      % (len(bold_tail), 100.0 * len(bold_tail) / len(paras)))

print()
PAT = [
    (r"——",            "破折号插入语"),
    (r"其一|其二|其三",  "其一/其二/其三"),
    (r"[^：\n]{2,20}：", "标题里的冒号"),
    (r"故|因此|由此|据此", "故/因此/由此/据此"),
    (r"须|应|需|不得|不宜", "规范性动词"),
    (r"非[一-鿿]",     "否定式强调"),
    (r"该规程|该判据|该原则", "重复的指称"),
    (r"，(?=[一-鿿]{0,6}[，、])", "并列逗号堆叠"),
]
for pat, name in PAT:
    n = sum(len(re.findall(pat, l)) for l in lines)
    print("  %-16s %4d" % (name, n))

print()
# sentence length distribution -- machine prose is very long-sentenced
text = "\n".join(body)
sents = [s for s in re.split(r"[。；]", text) if len(s.strip()) > 5]
L = sorted(len(s.strip()) for s in sents)
if L:
    n = len(L)
    print("  句子数 %d，最短 %d，中位 %d，P90 %d，最长 %d"
          % (n, L[0], L[n // 2], L[int(n * 0.9)], L[-1]))
    over80 = sum(1 for x in L if x > 80)
    over120 = sum(1 for x in L if x > 120)
    print("  >80 字  %d 句（%.0f%%）" % (over80, 100.0 * over80 / n))
    print("  >120 字 %d 句（%.0f%%）" % (over120, 100.0 * over120 / n))
    print("  短句（<25 字）%d 句（%.0f%%）"
          % (sum(1 for x in L if x < 25), 100.0 * sum(1 for x in L if x < 25) / n))

print()
print("  标题样式：")
for l in lines:
    m = re.match(r"^(#{2,4})\s+(.*)$", l.strip())
    if m:
        t = m.group(2)
        mark = "  ← 冒号标题" if re.match(r"^.{2,20}：", t) else ""
        print("    %-34s%s" % (t[:32], mark))