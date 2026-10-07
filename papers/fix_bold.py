#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Re-pair bold markers broken by the dash-to-full-stop rewrite.

"——" -> "。" turned "…一个字节未省——**命中只换了介质**。根因…" into
"…一个字节未省。**命中只换了介质**。根因…", which is fine, but where the dash sat directly
against a bold span it split the ** pair and left an unmatched marker, which the builder then
rendered as a literal asterisk. Count them, repair by pairing, and refuse to write if any
survive.
"""
import re, pathlib, sys

P = pathlib.Path("papers/论文-慢层只读一次原则.md")
lines = P.read_text(encoding="utf-8").splitlines()

fixed = 0
for i, ln in enumerate(lines):
    n = ln.count("**")
    if n % 2:
        # an odd count means a span was cut. The safest repair is to close it at the end of
        # the sentence it opened in, i.e. before the first 。 that follows the opener.
        m = re.search(r"\*\*([^*]{0,80}?)。", ln)
        if m:
            ln = ln[:m.end() - 1] + "**" + ln[m.end() - 1:]
            fixed += 1
        else:
            ln = ln.replace("**", "")
            fixed += 1
    lines[i] = ln

md = "\n".join(lines) + "\n"

# report anything still broken before writing
bad = [(i + 1, l) for i, l in enumerate(lines) if l.count("**") % 2]
if bad:
    print("  ★ 仍有未配对的加粗标记，不写出：")
    for i, l in bad[:5]:
        print("    第 %d 行: %s" % (i, l[:100]))
    sys.exit(1)

P.write_text(md, encoding="utf-8")
print("  修复 %d 处被切断的加粗标记" % fixed)
print("  当前加粗片段 %d 处" % (md.count("**") // 2))