#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Inspect what the captions actually look like inside the DOCX."""
import pathlib, re, zipfile

DOCX = pathlib.Path("papers/提交稿-缓存高命中与词元低输出.docx")
with zipfile.ZipFile(DOCX) as z:
    xml = z.read("word/document.xml").decode("utf-8")
txt = re.sub(r"</w:p>", "\n", xml)
txt = re.sub(r"<[^>]+>", "", txt)
txt = txt.replace("&amp;", "&").replace("&lt;", "<").replace("&gt;", ">")

print("  所有含「表」的行：")
for line in txt.split("\n"):
    s = line.strip()
    if "表" in s and len(s) < 130:
        print("    ·" + s[:120])

print()
print("  所有含 Table 的行：")
for line in txt.split("\n"):
    s = line.strip()
    if "Table" in s and len(s) < 130:
        print("    ·" + s[:120])

print()
print("  所有含「phase-resolved」或「re-measured」的行：")
for line in txt.split("\n"):
    s = line.strip()
    if "phase-resolved" in s or "re-measured" in s or "Six counter" in s:
        print("    ·" + s[:120])