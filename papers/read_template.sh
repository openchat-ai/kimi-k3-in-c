#!/bin/bash
# Read the template's text and its formatting. wvText for the content, then the raw .doc for
# the style names and any explicit font/size attributes, since wvSummary produced nothing.
set -u
T=/tmp/jsjkx_template.doc

echo "===================== wvText: 模板正文"
wvText "$T" 2>/dev/null | sed -n '1,120p' | cat -n | sed 's/^/  /'

echo
echo "===================== 从 .doc 里找样式名与字体/字号属性"
echo "== UTF-16LE 字符串里的样式与字体"
strings -el "$T" | grep -aiE "正文|标题|Heading|Normal|摘要|关键词|参考文献|作者|单位|图|表|宋体|黑体|楷体|仿宋|Times" \
  | sort -u | head -40 | sed 's/^/  /'

echo
echo "== 单字节字符串里的排版参数"
strings "$T" | grep -aiE "Times New Roman|SimSun|SimHei|KaiTi|FangSong|fontsz|mar[ltbrd]|dxa" \
  | sort -u | head -20 | sed 's/^/  /'