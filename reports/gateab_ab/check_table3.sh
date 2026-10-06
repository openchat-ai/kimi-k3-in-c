#!/bin/bash
# Table 3 (the LRU-vs-heat comparison) is cited in section 4.5 and again in the conclusion
# ("expert-stage READ falls from 25.83 to 20.99 GB/token, output speed up about 10%"). Table A.1
# maps it to ledger lines :17, :21, :58-:67, but those lines hold a byte-classification table
# (S1/S2 segments) and a BF8 compression estimate -- no policy comparison. And 20.99 appears
# nowhere in the ledger. Check all four rows of table 3 before concluding anything.
set -u
cd /mnt/f/kimi-k3-in-c
L=papers/byteflow-matrix.md

echo "== 表 3 四个数据点在台账里的存在性"
for v in 107\.27 96\.35 106\.52 100\.17 17\.44 25\.83; do
  n=$(grep -cE "$v" "$L")
  printf "  %-10s %s 次" "$v" "$n"
  if [ "$n" -gt 0 ]; then
    printf "   行号: %s" "$(grep -nE "$v" "$L" | cut -d: -f1 | paste -sd, -)"
  fi
  echo
done

echo
echo "== 台账里有 policy / LRU 对照的段落吗"
grep -niE 'LRU' "$L" | head -10 | cut -c1-150 | sed 's/^/   /'

echo
echo "== cgroup 26 GB / gen 8 / 逐 id 一致 这三个限定词"
for v in 'cgroup' '26 ?GB' 'gen ?8' '逐 ?id|输出逐|词元.?identical' 'n=3'; do
  printf "  %-22s %s 次\n" "$v" "$(grep -cE "$v" "$L")"
done