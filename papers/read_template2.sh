#!/bin/bash
# Two failures in one: /tmp is not persistent across WSL sessions, so the template was gone;
# and wvText needs an output file argument. Re-fetch into /root and read it properly.
set -u
export DEBIAN_FRONTEND=noninteractive
T=/root/jsjkx_template.doc
mkdir -p /root

if [ ! -s "$T" ]; then
  echo "== 下载模板到 /root（/tmp 跨 WSL 会话不保留）"
  curl -sSL -A "Mozilla/5.0" -o "$T" \
    https://www.jsjkx.com/attached/image/20240711/20240711091132_401.doc
  ls -l "$T" | awk '{print "  "$5" bytes"}'
fi
file "$T" | sed 's/^/  /'

echo
echo "===================== wvText 提取的模板正文"
wvText "$T" /root/tpl.txt 2>/dev/null
if [ -s /root/tpl.txt ]; then
  sed -n '1,110p' /root/tpl.txt | cat -n | sed 's/^/  /'
else
  echo "  wvText 无输出，改用 antiword"
  antiword -w 0 "$T" 2>/dev/null | sed -n '1,110p' | cat -n | sed 's/^/  /'
fi

echo
echo "===================== 样式名与字体"
strings -el "$T" | grep -aiE "正文|标题|Heading|Normal|摘要|关键词|参考文献|作者|单位|图|表|宋体|黑体|楷体|仿宋|Times" \
  | sort -u | head -40 | sed 's/^/  /'