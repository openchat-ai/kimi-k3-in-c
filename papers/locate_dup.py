#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Locate the verbatim-duplicated sentence and list §4's paragraph budget."""
import re, pathlib, collections

lines = pathlib.Path("papers/论文-慢层只读一次原则.md").read_text(
    encoding="utf-8").splitlines()

# ---- 1. where does the exact duplicate live? ----
print("  逐字重复的整句")
target = None
for i, ln in enumerate(lines):
    if "接入高速盘后引擎自报命中率满格" in ln:
        if target is None:
            target = i
        else:
            for j in (target, i):
                sec = next((f"§{l.split()[1]}" for l in reversed(lines[:j])
                            if re.match(r"^## \d\s", l.strip())), "前置")
                print("    第 %4d 行 (%s)  长 %d" % (j + 1, sec, len(lines[j])))
            print()

# ---- 2. §4 paragraph budget, longest first ----
start = next(i for i, l in enumerate(lines) if re.match(r"^## 4\s", l.strip()))
end = next(i for i, l in enumerate(lines) if re.match(r"^## 5\s", l.strip()))
sec4 = [(i + 1, l.strip()) for i, l in enumerate(lines[start:end], start) if l.strip()]
print("  §4 共 %d 个非空行，%d 字符；按长度排序" % (len(sec4), sum(len(l) for _, l in sec4)))
for ln_no, t in sorted(sec4, key=lambda x: -len(x[1]))[:12]:
    kind = "表" if t.startswith("|") else ("图" if t.startswith("!") or t.startswith("图") else "文")
    print("    %4d行 %3d字 [%s] %s" % (ln_no, len(t), kind, t[:62]))

# ---- 3. how much of §4 is markdown table plumbing vs prose ----
tbl_chars = sum(len(t) for _, t in sec4 if t.startswith("|"))
prose = sum(len(t) for _, t in sec4 if not t.startswith("|"))
print()
print("  §4 中表格行合计 %d 字符，正文散文合计 %d 字符" % (tbl_chars, prose))

# ---- 4. same for §5 ----
s5 = next(i for i, l in enumerate(lines) if re.match(r"^## 5\s", l.strip()))
e5 = next(i for i, l in enumerate(lines) if re.match(r"^## 6\s", l.strip()))
sec5 = [l.strip() for l in lines[s5:e5] if l.strip()]
t5 = sum(len(t) for t in sec5 if t.startswith("|"))
p5 = sum(len(t) for t in sec5 if not t.startswith("|"))
print("  §5 共 %d 字符；表格行 %d，散文 %d" % (len(sec5) and sum(len(t) for t in sec5), t5, p5))