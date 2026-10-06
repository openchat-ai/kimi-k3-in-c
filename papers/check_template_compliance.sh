#!/bin/bash
# The journal's own template (jsjkx_template.doc, 4 pages, saved 2024-07-11) states:
#   摘要 不少于300字
#   Abstract 不少于300词
#   正文采用双栏排版
#   图表题 6号；表题在上、图题在下，居中
#   我刊为黑白印刷，图形中建议不出现彩色
#   中图分类号 细化到3位数字
#   摘要中 请勿使用"本文""我们"等第一人称表述
# Two of these contradict what a third-party intermediary said and what I did on its word.
# Check every one against the actual manuscript.
set -u
cd /mnt/f/kimi-k3-in-c
P=papers/论文-慢层只读一次原则.md

echo "== 1 摘要字数（模板：不少于 300 字）"
python3 - <<'PY'
import re, pathlib
t = pathlib.Path("papers/论文-慢层只读一次原则.md").read_text(encoding="utf-8")
ab = re.search(r"## 摘要\s*\n\s*(.+?)\n## ", t, re.S).group(1).strip()
cjk = len(re.findall(r"[\u4e00-\u9fff]", ab))
print(f"   纯汉字 {cjk}   {'*** 不足 300 ***' if cjk < 300 else 'ok'}")
print("   （我按第三方站点的'200-400字'把它从约500压到298，官方模板是'不少于300字'）")
PY

echo
echo "== 2 英文摘要词数（模板：不少于 300 词）"
python3 - <<'PY'
import re, pathlib
t = pathlib.Path("papers/论文-慢层只读一次原则.md").read_text(encoding="utf-8")
m = re.search(r"## High Cache Hit Rate.*?\n(.*)$", t, re.S)
if not m:
    print("   *** 未找到英文摘要节 ***")
else:
    body = m.group(1)
    w = len(re.findall(r"[A-Za-z][A-Za-z'-]*", body))
    print(f"   词数 {w}   {'*** 不足 300 词 ***' if w < 300 else 'ok'}")
PY

echo
echo "== 3 摘要是否用了第一人称（模板：勿用'本文''我们'）"
python3 - <<'PY'
import re, pathlib
t = pathlib.Path("papers/论文-慢层只读一次原则.md").read_text(encoding="utf-8")
ab = re.search(r"## 摘要\s*\n\s*(.+?)\n## ", t, re.S).group(1)
hits = [w for w in ("本文", "我们", "笔者", "本研究", "本实验") if w in ab]
print(f"   {'命中: ' + '、'.join(hits) if hits else '未命中 ✓'}")
PY

echo
echo "== 4 中图分类号（模板：细化到 3 位数字，如 TPXXX）"
grep -aoE "中图分类号[:：] *[A-Z]+[0-9]*" "$P" | head -2 | sed 's/^/   /'
d=$(grep -aoE "中图分类号[:：] *[A-Z]+([0-9]+)" "$P" | head -1 | grep -oE "[0-9]+$")
echo "   数字部分位数: ${#d}   $([ ${#d} -ge 3 ] && echo ok || echo '*** 不足 3 位 ***')"

echo
echo "== 5 关键词数量（模板：5~8 个）"
k=$(grep -aoE "关键词[：:].*" "$P" | head -1)
echo "   $k"
n=$(grep -aoE "关键词[：:].*" "$P" | head -1 | grep -oE "[^；;、,，]\{2,\}" | wc -l)
echo "   计得约 $n 个   $([ "$n" -ge 5 ] && [ "$n" -le 8 ] && echo ok || echo '*** 超出 5~8 ***')"

echo
echo "== 6 两张图是否含彩色（模板：黑白印刷，建议不出现彩色）"
for f in docs/images/bytes_paradox.png docs/images/trunk_cache_split.png; do
  printf "   %-38s " "$f"
  if command -v identify >/dev/null 2>&1; then
    identify -format "%[colorspace] depth=%z " "$f" 2>/dev/null
  fi
  python3 - "$f" <<'PY'
import sys, zlib, struct
p = sys.argv[1]
d = open(p, "rb").read()
# sRGB / gAMA chunks mean colour intent; type 2 (truecolour) or 6 (truecolour+alpha) means RGB data
typ = struct.unpack(">I", d[24:28])[0]
ihdr = struct.unpack(">IIBBBBB", d[16:16+13])
ct = ihdr[2]
w, h = ihdr[0], ihdr[1]
has_gamma = b"gAMA" in d
has_srgb = b"sRGB" in d
print(f"  {w}x{h}  colourtype={ct} (2=RGB 0=grey 3=palette) "
      f"sRGB_chunk={has_srgb}  size={len(d)//1024}KB", end="  ")
print("*** 含彩色像素 ***" if ct in (2, 6) and b"PLTE" not in d else "灰度或调色板")
PY
done

echo
echo "== 7 双栏（模板：正文采用双栏排版）"
echo "   markdown 源无栏概念；需在生成的 Word 中设为双栏 —— 排版阶段处理"

echo
echo "== 8 图宽（模板：一般 ≤8cm，通栏 13~14cm）"
echo "   两图当前像素宽度:"
for f in docs/images/bytes_paradox.png docs/images/trunk_cache_split.png; do
  python3 -c "
import struct,sys
d=open('$f','rb').read()
w,h=struct.unpack('>II', d[16:24])
print(f'     $f  {w}x{h}px')
"
done