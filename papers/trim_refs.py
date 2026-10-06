#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Cut the bibliography from 18 to 14 and renumber the survivors.

The template asks for 只择最主要的列入. What counts as "主要" cannot be guessed from the
entry text alone, so the decision was made from where each entry is used:

  cut outright, cited nowhere : [9] PagedAttention, [10] FlightLLM
  cut, decorative only        : [3] GShard, [5] Mixtral -- both appear only inside the
                                one-clause MoE evolution chain in §1.1
  kept, load-bearing          : [8] Eyeriss (the empirical precedent for "slow layer read
                                once"), [11][12] (the closest prior work, so the novelty
                                positioning depends on them), [18] Amdahl (the degenerate
                                form of the bottleneck-device result)

That is 14, not the 12 originally suggested: reaching 12 would mean cutting references that
carry actual claims. [14] also carried a wrong path -- notes/byteflow-matrix.md, which does
not exist -- while the appendix text acknowledged the path was wrong without fixing it.

Every replacement is asserted; a miss aborts rather than leaving a dangling marker.
"""
import re, pathlib, sys

P = pathlib.Path("papers/论文-慢层只读一次原则.md")
md = P.read_text(encoding="utf-8")

m = re.search(r"^## 参考文献\s*$", md, re.M)
body, reflist = md[:m.start()], md[m.start():]
lines = reflist.splitlines()
entries = {}
for ln in lines:
    mm = re.match(r"^\[(\d+)\]\s*(.+)$", ln)
    if mm:
        entries[int(mm.group(1))] = mm.group(2)

DROP = {3, 5, 9, 10}
keep = sorted(n for n in entries if n not in DROP)
remap = {old: new for new, old in enumerate(keep, 1)}

# ---- 1. rewrite the two sentences whose markers are about to disappear ----
EDITS = [
    # §1.1 MoE evolution chain loses 分片[3] and 开源验证[5]
    ("经千亿级分片[3]、单专家路由[4]、开源验证[5]与细粒度专家切分[6]演进而来",
     "经单专家路由[4]与细粒度专家切分[6]等方向演进而来"),
    # §2.2 range [9-12] collapses to the two survivors
    ("系统汇报[9-12]", "系统汇报[11-12]"),
    ("调度/预取系统[9-12]", "调度/预取系统[11-12]"),
]
for old, new in EDITS:
    if old not in body:
        sys.exit("FATAL: 找不到待改写语句: %s" % old)
    body = body.replace(old, new)

# ---- 2. renumber every in-text marker in one pass (order-independent) ----
def sub_marker(mo):
    n = int(mo.group(1))
    if n in DROP:
        raise SystemExit("FATAL: 正文仍引用将被删除的文献 [%d]" % n)
    return "[%d]" % remap[n]

body, n_sub = re.subn(r"\[(\d+)\]", sub_marker, body)

# ---- 3. rebuild the list, and fix the ledger path in the old [14] (new [10]) ----
ledger_old = entries[14]
if "notes/byteflow-matrix.md" not in ledger_old:
    sys.exit("FATAL: 预期 [14] 含错误路径 notes/byteflow-matrix.md，实则没有，中止")
ledger_new = ledger_old.replace("notes/byteflow-matrix.md", "papers/byteflow-matrix.md")
entries_out = {}
for old in keep:
    entries_out[old] = ledger_new if old == 14 else entries[old]

newlist = "## 参考文献\n\n" + "\n".join(
    "[%d] %s" % (remap[o], entries_out[o]) for o in keep) + "\n\n"

# Everything after the LAST reference entry is not part of the list: the '---', the English
# title/abstract/keywords block and the author-bio block live there. Dropping md[m.end:]
# wholesale to fix a doubled list therefore deleted the English abstract along with it, which
# is how the English title stopped reaching the document.
_rl = reflist.splitlines()
_last = max(i for i, l in enumerate(_rl) if re.match(r"^\[\d+\]\s", l))
_tail = "\n".join(_rl[_last + 1:]).strip("\n")
if not _tail:
    sys.exit("FATAL: 文献表之后没有任何内容，疑似尾部丢失，中止")
if "High Cache Hit Rate" not in _tail or "作者简介" not in _tail:
    sys.exit("FATAL: 尾部缺少英文摘要块或作者简介块，中止")
newlist += _tail + "\n"

# md[m.end():] is deliberately not appended: it starts right after the heading and still
# contains every old entry, which doubled the list.
P.write_text(body + newlist, encoding="utf-8")
print("  文献表之后的尾部保留 %d 字符（含英文摘要块与作者简介块）" % len(_tail))

print("  删除 %d 条：%s" % (len(DROP), sorted(DROP)))
print("  保留 %d 条：%s" % (len(keep), keep))
print("  编号映射：%s" % ", ".join("%d→%d" % (o, remap[o]) for o in keep))
print("  正文引用标记改写 %d 处" % n_sub)
print("  [14]→[%d] 路径修正：notes/ → papers/" % remap[14])
saved = sum(len(entries[o]) + 6 for o in DROP)
print("  减少字符 %d，约合 %.0f 元" % (saved, saved * 0.2))