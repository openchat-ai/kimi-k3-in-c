#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Remove the self-deprecating talk about the principle being trivially derived.

平凡 is not a technical judgement. "This derivation is trivial" is rhetoric, not a finding, and
"what is trivial is the derivation rather than its role" is a distinction that parses but says
nothing a reader can use. It appeared three times, and twice in the first two sentences of the
abstract, so the paper opened by explaining its own organisation instead of stating its subject.

It is a leftover from the change that preceded option A. Option B had put 平凡 into the title to
pre-empt a reviewer calling the bound too shallow; when the author chose A the title went back to
their own wording, but the abstract and 1.3 kept the self-deprecation. The candour was never
wrong -- what the principle assumes does need to be stated -- but stating it as a defence of the
principle's shallowness is not the same thing, and the defence is what read as absurd.

Replaced with the scope statement that was buried inside it: two named assumptions, and the fact
that the criterion rests on the counters being trustworthy rather than on the bound being deep.
That is useful to a reader. The apology was not.
"""
import pathlib, sys

P = pathlib.Path("papers/论文-慢层只读一次原则.md")
md = P.read_text(encoding="utf-8")
orig = md

REPL = [
    # ---- abstract, first sentence ----
    ("所用原则——慢速层只读一次——由定义与两条显式假设直接导出，不含隐藏引理。"
     "**平凡的是这条原则的推导，不是它的作用：正因为它不需要引用，"
     "它才固定了一个任何字节台账都能逐行核对的口径，而可核对是全文其余部分的前提。**",
     "所用原则——慢速层只读一次——由定义与两条显式假设直接导出，不含隐藏引理，"
     "因而任何字节级台账都能逐行核对而不必先核对文献。"),
    # ---- 1.2 ----
    ("**平凡的是这条原则的推导，不是它的作用。** 它平凡到不需要引用，"
     "这既是它的弱点（不足以单独支撑一篇论文）也是它的长处（审阅者无法在推导上挑刺）。"
     "而真正决定判据能否成立的地方在两处：**计出来的数是否可信（§3.2）**，"
     "以及**字节级台账与时间账为什么不能混用（第 4.6 节）**。"
     "这两处都不是原理能回答的，本文的主要工作也在它们上面。",
     "**判据能否成立，取决于两件与这条原则无关的事：计出来的数是否可信（§3.2），"
     "以及字节级台账与时间账为什么不能混用（第 4.6 节）。** 这两处都不是原则能回答的，"
     "本文的主要工作也在它们上面。"),
    # ---- 1.3 contribution 5 ----
    ("**该原则由两条显式假设导出、推导平凡，其价值不在于深，"
     "而在于它固定了一个不需要引用即可核对的口径**：正因为它简单，"
     "判据的验收标准才能被逐行回查，而回查是本篇其余工作的前提。",
     "**该原则由两条显式假设导出，不含隐藏引理，因而无需先核对文献即可使用**："
     "判据的验收标准由此可以被逐行回查，而回查是本篇其余工作的前提。"),
]

miss = []
for a, b in REPL:
    if a not in md:
        miss.append(a[:44])
        continue
    md = md.replace(a, b, 1)
    print("  ✓ 行首替换：%s…" % a[:34])

P.write_text(md, encoding="utf-8")
print("  替换 %d/%d 处，篇幅变化 %+d 字符" % (len(REPL) - len(miss), len(REPL),
                                       len(md) - len(orig)))
for m in miss:
    print("  ★ 未匹配：%s" % m)

md2 = P.read_text(encoding="utf-8")
left = md2.count("平凡")
print()
print("  残留「平凡」: %d %s" % (left, "✓" if left == 0 else "★"))
print("  保留的假设声明：%d 处「两条显式假设」" % md2.count("两条显式假设"))
for i, l in enumerate(md2.splitlines(), 1):
    if "不含隐藏引理" in l:
        j = l.find("所用原则")
        if j < 0:
            j = l.find("两条显式假设")
        print("  行%4d  …%s…" % (i, l.strip()[max(0, j - 10):j + 74].replace("\n", " ")))
if miss or left:
    sys.exit("★ 仍有残留")