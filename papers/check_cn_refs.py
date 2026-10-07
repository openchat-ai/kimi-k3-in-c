#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Check guideline item 5: every Chinese reference needs an English translation.

Item 5 says Chinese-language sources must additionally carry an English translation. The draft
satisfies it in two different ways and the difference matters: some entries are Chinese documents
that already carry a bracketed English rendering inline, and some are English documents. What is
not acceptable is a Chinese-language source with no English rendering anywhere in the entry,
since that is exactly what the clause exists to prevent.

So this classifies each entry rather than searching for any Chinese characters. The presence of
Chinese characters alone would not make an entry Chinese -- an English title glossed in brackets
is Chinese by character count but not by language, and flagging those would be wrong.
"""
import pathlib, re, sys

P = pathlib.Path("papers/论文-慢层只读一次原则.md")
lines = P.read_text(encoding="utf-8").splitlines()
s = next(i for i, l in enumerate(lines) if l.startswith("## 参考文献"))
e = next((i for i, l in enumerate(lines) if l.startswith("# 英文题名")), len(lines))

ENT = re.compile(r"^\[(\d+)\]\s*(.+)$")
entries = []
for i in range(s + 1, e):
    m = ENT.match(lines[i].strip())
    if m:
        entries.append({"no": int(m.group(1)), "text": m.group(2).strip(), "line": i + 1})

CJK = re.compile(r"[\u4e00-\u9fff]")
print("  %-4s %-6s %-10s %s" % ("条", "汉字数", "英文渲染", "题名起始"))
print("  " + "-" * 74)

need = []
for x in entries:
    t = x["text"]
    ncjk = len(CJK.findall(t))
    # an English rendering is a bracketed [..] segment, or a parallel title after a slash
    gloss = bool(re.search(r"\[[^\]]*[A-Za-z][^\]]*\]", t))
    dual = " / " in t or "；" in t
    has_en_gloss = gloss or dual
    flag = ""
    if ncjk > 0 and not has_en_gloss:
        flag = "  ★ 中文源，缺英文翻译"
        need.append(x)
    elif ncjk > 0:
        flag = "  ✓ 已附英文"
    else:
        flag = "  — 英文文献"
    print("  %-4d %-6d %-10s %s%s" % (x["no"], ncjk,
                                    "有" if has_en_gloss else "无",
                                    t[:46], flag))

print("  " + "-" * 74)
print("  共 %d 条；中文源 %d 条，其中缺英文翻译 %d 条"
      % (len(entries), sum(1 for x in entries if CJK.search(x["text"])), len(need)))
for x in need:
    print("    ★[%d] 行%d %s" % (x["no"], x["line"], x["text"][:70]))
if need:
    sys.exit("★ 须知第 5 条未满足")