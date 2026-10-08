#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Print the prose lines that hold numbers with no table behind them, so each can be placed."""
import pathlib, re

P = pathlib.Path("papers/论文-慢层只读一次原则.md")
lines = P.read_text(encoding="utf-8").splitlines()
END = next((i for i, l in enumerate(lines) if l.startswith("# 英文题名")), len(lines))

WANT = [260, 269, 270, 275, 283, 284, 285, 287, 290]
for ln in WANT:
    if ln > END:
        continue
    s = lines[ln - 1].strip()
    if not s:
        continue
    print("== 行%d （%d 字）" % (ln, len(s)))
    for part in re.split(r"(?<=。)", s):
        if part.strip():
            print("   ·" + part.strip())
    print()