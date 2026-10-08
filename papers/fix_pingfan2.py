#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""The remaining two: the abstract's first sentence, and 1.2's first item.

Both make the same kind of move the previous pass removed -- they justify the principle by its
shallowness. 1.2 goes further and says the short derivation means a reviewer will find nothing to
attack, which is a sentence about the refereeing process rather than about the reader's problem.
The abstract states the same disclosure in the same shape, which is why the first pass missed it:
the wording had drifted once already and no longer matched.

What survives is the part a reader can use: the principle rests on two named assumptions and needs
no literature, so any byte ledger can be checked against it.
"""
import pathlib, sys

P = pathlib.Path("papers/论文-慢层只读一次原则.md")
md = P.read_text(encoding="utf-8")
orig = md

REPL = [
    ("所用原则——慢速层只读一次——由定义与两条显式假设直接导出，不含隐藏引理。",
     "所用原则——慢速层只读一次——由定义与两条显式假设直接导出，不含隐藏引理，"
     "因而任何字节级台账都能逐行核对而不必先核对文献。"),
    ("平凡的是它的推导，不是它的作用：正因为它不需要引用，"
     "它才固定了一个任何字节台账都能逐行核对的口径，而可核对是全文其余部分的前提。",
     "判据能否成立，取决于计出来的数是否可信，而不是这条原则是否深刻。"),
    ("标尺是慢速层只读一次原则（§3.1），它的推导很短——由定义与两条显式假设直接导出，"
     "不含隐藏引理。**短在这里是优点：原则不依赖任何文献，因此审阅者在推导上无处挑刺；"
     "而它一旦成立，就固定了判据可以被逐行核对的那个原点。**",
     "标尺是慢速层只读一次原则（§3.1）：由定义与两条显式假设直接导出，不含隐藏引理，"
     "因而无需先核对文献即可使用，判据一旦成立，就固定了可以被逐行核对的原点。"),
]

miss = []
for a, b in REPL:
    if a not in md:
        miss.append(a[:40])
        continue
    md = md.replace(a, b, 1)
    print("  ✓ %s…" % a[:38])

P.write_text(md, encoding="utf-8")
print("  替换 %d/%d 处，篇幅变化 %+d 字符" % (len(REPL) - len(miss), len(REPL),
                                       len(md) - len(orig)))
for m in miss:
    print("  ★ 未匹配：%s" % m)

md2 = P.read_text(encoding="utf-8")
print()
for w in ("平凡", "挑刺", "无厘头"):
    n = md2.count(w)
    print("  残留「%s」: %d %s" % (w, n, "✓" if n == 0 else "★"))
print()
print("  摘要开头：")
for i, l in enumerate(md2.splitlines(), 1):
    if "所用原则" in l:
        print("    " + l.strip()[:150])
if miss:
    sys.exit("★ 有未匹配项")