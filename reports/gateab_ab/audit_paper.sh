#!/bin/bash
# Audit the paper's own numbers against the ledger lines it cites. Zero cost, no re-run: the
# paper claims every headline figure is traceable to notes/byteflow-matrix.md by line number,
# and table A.1 lists those mappings. This checks the mappings actually say what is claimed --
# the cheapest possible reproducibility test, and the one a reviewer would do first.
set -u
cd /mnt/f/kimi-k3-in-c
# The paper cites notes/byteflow-matrix.md for every headline figure, but the file is at
# papers/byteflow-matrix.md. There is no notes/ directory in the tree. So the ledger exists and
# every mapping in table A.1 is checkable, but the path a reviewer would follow is wrong.
L=papers/byteflow-matrix.md
if [ ! -r "$L" ]; then echo "LEDGER MISSING: $L -- every paper number is unsourced"; exit 1; fi
echo "ledger: $L  ($(wc -l < "$L") lines)"
echo

show() {   # $1 line number, $2 what the paper claims
  echo "  --- :$1   paper claims: $2"
  if [ "$1" -gt "$(wc -l < "$L")" ]; then echo "      OUT OF RANGE"; return 1; fi
  sed -n "${1}p" "$L" | cut -c1-150 | sed 's/^/      /'
}

echo "== 核心：每词元 25.83 GB"
show 311 "92x16x17.5 MB 口径"
show 390 "阶段A 实测 READ/词元 25.83 GB"
show 392 "阶段A 实测 READ/词元 25.83 GB"
echo
echo "== 核心：专家段与端到端耗时"
show 392 "专家段 303.58 s/词元，端到端占比 94%"
show 394 "端到端 324.36 s/词元"
echo
echo "== 核心：distinct 集约 176 GB"
show 324 "distinct 集 10,010 个"
show 326 "≈176 GB"
echo
echo "== 介质刻画"
show 286 "低速盘 84 MB/s（D-state）"
show 289 "低速盘 84 MB/s（D-state）"
show 453 "高速盘冷读 588 MB/s"
show 454 "高速盘冷读 588 MB/s"
echo
echo "== 对照实验"
show 355 "专家段 303→191.6 s（−37%）"
show 363 "专家段 191.6 s"
echo
echo "== 阶段 B 与 KV 回放"
show 457 "高速盘命中 19.1 GB/词元、低速盘 miss 6.7 GB"
show 443 "稳态尾段 27 GB/16 词元"
show 439 "KV 11,697 distinct 键、无逐出"
echo
echo "== 长程输出速度"
show 418 "seconds_per_token 262.78"
echo
echo "== 结论段引用的几个数是否也在台账里"
for pat in "25.83" "176" "10,010\|10010" "588" "191.6" "6.7" "19.1" "11,697\|11697"; do
  n=$(grep -c "$pat" "$L" 2>/dev/null || echo 0)
  printf "  %-22s 出现 %s 次\n" "$pat" "$n"
done