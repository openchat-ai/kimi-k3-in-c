#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Print the 5.2 lines holding the most-repeated figures."""
import pathlib

P = pathlib.Path("papers/论文-慢层只读一次原则.md")
lines = P.read_text(encoding="utf-8").splitlines()
for ln in (344, 356, 358, 368, 370, 373, 374, 378, 382, 384, 388, 390):
    s = lines[ln - 1].strip()
    if s:
        print("== 行%d" % ln)
        print("   " + s[:300])
        print()