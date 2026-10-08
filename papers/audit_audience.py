#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Find text written to somebody other than the reader.

The author stated the rule: the audience of a paper is the reader. Several edits this session were
aimed at a different audience and the tell is the same each time -- the sentence is about what a
referee, an editor or a search index will do with the text, rather than about what a reader trying
to use the method needs to know. Such sentences are not wrong, they are addressed elsewhere, and a
reader can tell.

This lists every candidate with its line so each can be judged, and separates the ones that belong
in the administrative block at the end of the paper -- where addressing the editor is the point --
from ones sitting in the body, where it is not.
"""
import pathlib, re, sys

P = pathlib.Path("papers/论文-慢层只读一次原则.md")
lines = P.read_text(encoding="utf-8").splitlines()
END = next((i for i, l in enumerate(lines) if l.startswith("# 英文题名")), len(lines))

# where the administrative block starts
ADMIN = next((i for i, l in enumerate(lines)
              if l.startswith("# 作者简介")), len(lines))

# 第 N 条 alone also matches the four-step order's "第 2 条", so a citation of a journal rule
# must be qualified by 须知 or 投稿知 before it counts as an address to the editor.
AUDIENCE = re.compile(
    r"审稿人|审阅者|评审|审稿|审人|编辑部|本刊|投稿须知|投稿时|见刊|版面费|"
    r"录用|投稿|须知第|投稿知第|模板要求|格式要求|查重|"
    r"可能被拒|拒稿|送审|一校|自校|清样|版权")

print("  %-5s %-8s %s" % ("行", "位置", "句子"))
print("  " + "-" * 76)
body_hits = []
admin_hits = []
for i, l in enumerate(lines, 1):
    if not AUDIENCE.search(l):
        continue
    where = "行政块" if i > ADMIN else "正文"
    for part in re.split(r"(?<=。)", l.strip()):
        if AUDIENCE.search(part):
            print("  %-5d %-8s %s" % (i, where, part[:96]))
            (admin_hits if i > ADMIN else body_hits).append(i)
            break

print("  " + "-" * 76)
print("  正文 %d 处 / 行政块 %d 处" % (len(body_hits), len(admin_hits)))
print()
if body_hits:
    print("  ★ 正文中写给审稿人或编辑的句子：")
    for i in body_hits:
        print("    行%d" % i)
    sys.exit("★ 正文含非读者受众的表述")
print("  ✓ 正文无写给审稿人或编辑的句子")
print("  （行政块 %d 处是稿件信息，按其用途应保留）" % len(admin_hits))