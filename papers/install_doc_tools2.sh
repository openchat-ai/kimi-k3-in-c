#!/bin/bash
# apt is blocked by an interrupted dpkg. Run --configure -a first, then install. If that stays
# broken, say so plainly rather than reporting the template as unreadable.
set -u
export DEBIAN_FRONTEND=noninteractive
echo "== dpkg --configure -a"
dpkg --configure -a 2>&1 | tail -5 | sed 's/^/  /'
echo
echo "== 装 antiword / wv"
apt-get -qq install -y antiword wv 2>&1 | tail -6 | sed 's/^/  /'
echo
for t in antiword wvText wvHtml; do
  printf "  %-8s " "$t"
  command -v "$t" >/dev/null && echo "有" || echo "无"
done