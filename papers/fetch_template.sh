#!/bin/bash
# Fetch the journal's own submission template and extract its actual typesetting parameters.
# Fonts, sizes, line spacing and margins must come from the template, not from taste -- the
# editorial office typesets against it. It is a .doc (binary Word 97-2003), so strings first;
# if that is not enough, antiword/catdoc will be tried.
set -u
cd /mnt/f/kimi-k3-in-c
OUT=/tmp/jsjkx_template.doc
URL=https://www.jsjkx.com/attached/image/20240711/20240711091132_401.doc

echo "== 下载"
curl -sSL -A "Mozilla/5.0" -o "$OUT" "$URL"
ls -l "$OUT" | awk '{print "  "$5" bytes"}'
file "$OUT" 2>/dev/null | sed 's/^/  /'

echo
echo "== 文件头（判断是真 .doc 还是 HTML 错误页）"
head -c 8 "$OUT" | od -An -tx1 | sed 's/^/  /'
if head -c 200 "$OUT" | grep -qi "DOCTYPE\|<html"; then
  echo "  *** 下到的是 HTML 页面而非文档 ***"
  head -c 300 "$OUT" | sed 's/^/  /'
  exit 1
fi

echo
echo "== 是否有 OLE 复合文档头"
if head -c 8 "$OUT" | od -An -tx1 | grep -q "d0 cf 11 e0"; then echo "  是 OLE2 复合文档（真 .doc）"; else echo "  不是 OLE2 —— 可能是 RTF 或纯文本"; fi

echo
echo "== RTF 头部？"
head -c 40 "$OUT" | sed 's/^/  /'
echo

echo
echo "== strings 里可见的排版关键字"
strings -el "$OUT" 2>/dev/null | grep -aiE "宋体|黑体|楷体|仿宋|Times New Roman|小四|五号|四号|单倍|倍线|行距|页边距|A4|摘要|关键词|参考文献|图 |表 " | \
  sort -u | head -60 | sed 's/^/  /'

echo
echo "== ASCII strings 里的版式线索"
strings "$OUT" 2>/dev/null | grep -aiE "Times New Roman|SimSun|SimHei|fontsz|mar[ltbrd]|A4|abstract|keyword" | sort -u | head -30 | sed 's/^/  /'

echo
echo "== 转换工具是否可用"
for t in antiword catdoc libreoffice soffice wvText; do
  command -v "$t" >/dev/null && echo "  $t 有" || true
done