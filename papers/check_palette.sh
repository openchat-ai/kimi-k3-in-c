#!/bin/bash
# Two things left open: the PNGs are colourtype 8 (indexed), and an indexed palette may hold
# colour -- "palette" is not the same as "grey", and the journal prints in black and white.
# And the keywords grep returned nothing, which is more likely my pattern than a missing line.
set -u
cd /mnt/f/kimi-k3-in-c

echo "== 论文里的关键词行到底怎么写的"
grep -anE "关键词|Keywords|key ?word" papers/论文-慢层只读一次原则.md | head -6 | \
  cut -c1-150 | sed 's/^/  /'

echo
echo "== 调色板是否真为灰度（colourtype=8 索引色，最多 256 色）"
python3 - <<'PY'
import struct, zlib, pathlib
for name in ("docs/images/bytes_paradox.png", "docs/images/trunk_cache_split.png"):
    d = pathlib.Path(name).read_bytes()
    w, h, depth, ct = struct.unpack(">IIBB", d[16:26])
    # walk chunks for PLTE
    off, plte = 8, None
    while off < len(d):
        ln = struct.unpack(">I", d[off:off+4])[0]
        typ = d[off+4:off+8]
        if typ == b"PLTE":
            plte = d[off+8:off+8+ln]
            break
        off += 12 + ln
    if plte is None:
        print(f"  {name}: 无 PLTE（{w}x{h} ct={ct}）")
        continue
    n = len(plte)//3
    coloured = []
    for i in range(n):
        r, g, b = plte[3*i], plte[3*i+1], plte[3*i+2]
        if not (r == g == b):
            coloured.append((r, g, b))
    print(f"  {name}: {w}x{h}  调色板 {n} 色，其中非灰阶 {len(coloured)} 色")
    if coloured:
        print(f"     *** 含彩色，前 8 个: {coloured[:8]}")
        print(f"     该刊黑白印刷，模板明确'建议不出现彩色'")
    else:
        print("     全部为灰阶 ✓")
PY