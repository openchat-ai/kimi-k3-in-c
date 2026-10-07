#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Show what the reader actually sees on the lines around the abstract heading."""
import pathlib, reprlib

P = pathlib.Path("papers/论文-慢层只读一次原则.md")
raw = P.read_bytes()
print("  字节数 %d" % len(raw))
print("  含 CR: %s   含 CRLF: %s" % (b"\r" in raw, b"\r\n" in raw))
md = raw.decode("utf-8")
ls = md.splitlines()
print("  行数 %d" % len(ls))
print()
for k in range(5, 15):
    if k < len(ls):
        print("  %2d  %s" % (k + 1, reprlib.repr(ls[k])[:78]))

print()
for i, l in enumerate(ls):
    if "摘要" in l:
        print("  含「摘要」 行%d  %s" % (i + 1, reprlib.repr(l)[:78]))
        break
else:
    print("  ★ 全文无「摘要」")
    for i, l in enumerate(ls[:20]):
        if l.strip():
            print("    %2d  %s" % (i + 1, reprlib.repr(l)[:78]))