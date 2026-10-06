#!/bin/bash
# The template is a real OLE2 .doc but nothing here can read it: no antiword, catdoc, wvText or
# LibreOffice. The Chinese typesetting parameters -- body font, heading sizes, line spacing,
# margins -- are exactly what I must not guess, so get a reader. Start with the small ones;
# if apt works at all, consider libreoffice-writer for a real .doc -> .docx conversion, which
# would also give a Word-compatible output path for the manuscript itself.
set -u
export DEBIAN_FRONTEND=noninteractive
echo "== apt 可用性"
apt-get -qq update 2>&1 | tail -3 | sed 's/^/  /'
echo "  apt update 退出码=$?"

echo
echo "== 装小工具"
apt-get -qq install -y antiword wv 2>&1 | tail -5 | sed 's/^/  /'

echo
for t in antiword wvText wvHtml; do
  printf "  %-8s " "$t"
  command -v "$t" >/dev/null && echo "有" || echo "无"
done

if command -v antiword >/dev/null; then
  echo
  echo "== antiword 输出（模板正文）"
  antiword -w 0 /tmp/jsjkx_template.doc 2>/dev/null | head -70 | sed 's/^/  /'
fi