#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Inspect the tables inside the DOCX: do they have visible borders, and of what weight?

The builder sets t.style = "Table Grid". Whether that produces visible lines depends on whether
the style exists in the document the builder starts from and whether the theme carries the border
definitions -- and neither is visible from the builder source. So this reads the DOCX directly:
for every table it reports the table style, the explicit tblBorders, and the effective cell borders
found on the first row.
"""
import pathlib, re, zipfile, sys
from collections import Counter

DOCX = pathlib.Path("papers/提交稿-缓存高命中与词元低输出.docx")
with zipfile.ZipFile(DOCX) as z:
    doc = z.read("word/document.xml").decode("utf-8")
    names = z.namelist()
    try:
        styles = z.read("word/styles.xml").decode("utf-8")
    except KeyError:
        styles = ""

W = "{http://schemas.openxmlformats.org/wordprocessingml/2006/main}"
tables = re.findall(r"<w:tbl>.*?</w:tbl>", doc, re.S)
print("  DOCX 内表格 %d 张" % len(tables))
print("  styles.xml 存在：%s" % ("word/styles.xml" in names))
print()

print("  表格样式定义在 styles.xml 中：")
for nm in re.findall(r'<w:style [^>]*w:styleId="([^"]+)"', styles):
    if "Table" in nm or "table" in nm:
        print("    · %s" % nm)
print()

print("  逐表检查")
no_border = 0
for i, t in enumerate(tables, 1):
    st = re.search(r'<w:tblStyle w:val="([^"]+)"', t)
    style = st.group(1) if st else "（无，直接设边框）"
    tbl_borders = re.findall(r"<w:tblBorders>(.*?)</w:tblBorders>", t, re.S)
    tb = ""
    if tbl_borders:
        kinds = re.findall(r'<w:(top|left|bottom|right|insideH|insideV)[^/]*w:val="([^"]+)"',
                           tbl_borders[0])
        tb = ",".join("%s=%s" % (k, v) for k, v in kinds)
    # cell borders in the first data row
    first = re.search(r"<w:tr[ >].*?</w:tr>", t, re.S)
    cell = ""
    if first:
        cb = re.findall(r"<w:tcBorders>(.*?)</w:tcBorders>", first.group(0), re.S)
        cell = "有" if cb else "无"
    # count visible horizontal rules
    hrules = len(re.findall(r'<w:(?:insideH|bottom)[^>]*w:val="(?:single|double|thick)"', t))
    ok = bool(tbl_borders) or cell == "有"
    if not ok:
        no_border += 1
    print("    表%d  样式=%-16s  tblBorders=%-42s 单元格边框=%-3s 横线=%d %s"
          % (i, style[:16], (tb or "无")[:42], cell, hrules,
             "" if ok else "  ★ 无可见边框"))

print()
if no_border:
    sys.exit("★ %d 张表没有可见边框" % no_border)
print("  ✓ 全部表格均有边框定义")