#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Move appendix A out of the paper and into the reproduction attachment.

The journal's 投稿须知 item 17 already requires a separate 实验复现数据及环境配置说明
attachment, so the appendix has a natural home there rather than being deleted. Page-design
charges are levied per character (200元/千字符), so this is the largest single saving
available: the appendix is 4366 characters, about 873元.

Nothing is transcribed by hand -- the block is moved, and the four in-text pointers to
附录 A.1 are rewritten so no reference is left dangling.
"""
import re, pathlib, sys

PAPER = pathlib.Path("papers/论文-慢层只读一次原则.md")
ATT = pathlib.Path("papers/实验复现数据及环境配置说明.md")

md = PAPER.read_text(encoding="utf-8")
att = ATT.read_text(encoding="utf-8")

# ---- locate the appendix block ----
m = re.search(r"^## 附录 A.*?(?=^## 参考文献)", md, re.S | re.M)
if not m:
    sys.exit("FATAL: 未找到附录 A 区块")
block = m.group(0).rstrip() + "\n"

POINTER = """## 附录 A　台账说明与方法细节（随稿附件）

本附录全部内容已移入随稿附件《实验复现数据及环境配置说明》"附录 A"一节，随稿一并提交：
正文数字到台账行号的映射表（原表 A.1，共 20 条）、对照收益与乐观上界的差距、
2026-09-28 分相位实测的出处与复现、观测口径。依《计算机科学》投稿须知第 17 条，该附件与
正文同送外审，故正文所引全部行号仍可逐行回查，附件内路径与本仓库一致。

"""

# ---- 1. paper: replace the block with the pointer, fix in-text references ----
new_md = md[:m.start()] + POINTER + md[m.end():]

REPL = [
    ("出处见附录 A.1", "出处见随稿附件 A.1"),
    ("（附录 A）", "（随稿附件附录 A）"),
    ("见附录 A.1 的 KV 回放条目", "见随稿附件 A.1 的 KV 回放条目"),
]
hits = {}
for old, new in REPL:
    hits[old] = new_md.count(old)
    new_md = new_md.replace(old, new)

leftover = re.findall(r"附录 A\.1", new_md)
PAPER.write_text(new_md, encoding="utf-8")

# ---- 2. attachment: append the appendix, renamed as a section of the attachment ----
if "附录 A" in att and "台账说明与方法细节" in att:
    sys.exit("FATAL: 附件里已经有附录 A，避免重复追加")
att = att.rstrip() + "\n\n---\n\n" + block
ATT.write_text(att, encoding="utf-8")

print("  论文：附录 %d 字符 → 指针 %d 字符" % (len(block), len(POINTER)))
print("  正文引用改写：")
for k, v in hits.items():
    print("    %-28s ×%d" % (k, v))
print("  残留未改的『附录 A.1』：%d 处" % len(leftover))
if leftover:
    sys.exit("FATAL: 仍有指向已移出内容的引用，需人工处理")
print("  附件：已追加 %d 字符，现共 %d 字符" % (len(block), len(att)))