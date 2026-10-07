#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Convert the new figure to true greyscale and verify the PNG header, not the filename.

verify_docx.py reads the IHDR colour type and flagged image3.png as RGBA. A greyscale-capable
journal will print in black and white, so an RGBA file with grey pixels still relies on the
printer's colour handling. Earlier figures were named _grey.png by the pipeline step that
produced them; this one was written by a separate script, so the conversion has to happen
here rather than relying on the name.
"""
import pathlib, struct, sys

P = pathlib.Path("docs/images/byte_vs_time.png")
from PIL import Image

im = Image.open(P)
print("  转换前：%s  mode=%s" % (P.name, im.mode))
im.convert("L").save(P)
im2 = Image.open(P)
print("  转换后：mode=%s" % im2.mode)

# PNG IHDR colour type byte: 0 = greyscale, 2 = RGB, 6 = RGBA
data = P.read_bytes()
ct = data[25]
kind = {0: "灰度", 2: "RGB", 3: "调色板", 4: "灰度+alpha", 6: "RGBA"}.get(ct, "未知")
print("  IHDR colour type = %d (%s)" % (ct, kind))
if ct != 0:
    print("  ★ 仍非灰度，中止")
    sys.exit(1)
print("  ok")