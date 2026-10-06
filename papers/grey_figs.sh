#!/bin/bash
# 《计算机科学》prints in black and white and its template says 图形中建议不出现彩色. Both
# figures are RGBA truecolour (colourtype 6), so they must be converted rather than described
# as already grey. Earlier I misread the IHDR offsets and called them palette PNGs; this
# parses the chunks properly and reports what the pixel data actually is.
set -u
cd /mnt/f/kimi-k3-in-c
VENV=/root/docxenv
/root/docxenv/bin/pip install -q pillow 2>&1 | tail -2

for f in docs/images/bytes_paradox.png docs/images/trunk_cache_split.png; do
  echo "== $f"
  $VENV/bin/python - "$f" <<'PY'
import sys
from PIL import Image
p = sys.argv[1]
im = Image.open(p)
print(f"   原图 {im.mode} {im.size}")
rgb = im.convert("RGB")
# If every channel is already equal the image is grey in disguise and needs no conversion.
r, g, b = rgb.split()
grey_in_rgb = list(r.getdata()) == list(g.getdata()) == list(b.getdata())
if grey_in_rgb:
    print("   三通道已相等 —— 已是灰度，无需转换")
else:
    diff = sum(1 for pr, pg, pb in zip(r.getdata(), g.getdata(), b.getdata()) if not pr == pg == pb)
    print(f"   含彩色像素 {diff} 个（占 {100*diff/(im.size[0]*im.size[1]):.1f}%）→ 转灰度")
    out = p.replace(".png", "_grey.png")
    rgb.convert("L").save(out, optimize=True)
    print(f"   已写出 {out}")
PY
done