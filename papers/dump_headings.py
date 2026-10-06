#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Dump short non-empty paragraphs so the real heading text can be read, not guessed."""
from docx import Document

d = Document("papers/提交稿-缓存高命中与词元低输出.docx")
ps = [(p.text or "").strip() for p in d.paragraphs]
for i, t in enumerate(ps):
    if 0 < len(t) < 46 and t:
        print(f"{i:>4} {t!r}")