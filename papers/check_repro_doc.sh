#!/bin/bash
# A reproduction document that cites paths which do not exist is worse than no document: it
# tells a reviewer to look for something that was never recorded. Verify every path and every
# figure it quotes before it is attached to a submission.
set -u
cd /mnt/f/kimi-k3-in-c
D=papers/实验复现数据及环境配置说明.md
[ -r "$D" ] || { echo "document missing"; exit 1; }
echo "document: $(wc -l < "$D") lines"
fail=0

echo
echo "== paths it cites"
for p in \
  papers/byteflow-matrix.md \
  reports/gateab_ab/BENCH_PROTO.md \
  reports/gateab_ab/FINDINGS.md \
  reports/gateab_ab/v56_groupcheck \
  reports/gateab_ab/v58_mix/ratios.txt \
  reports/gateab_ab/v59_bisect \
  reports/gateab_ab/v62_policy/raw.tsv \
  reports/gateab_ab/test_memcap2.sh \
  reports/gateab_ab/audit_paper.sh \
  reports/gateab_ab/remap_paper.sh \
  reports/gateab_ab/DAY1/summary.txt \
  docs/images/bytes_paradox.png \
  docs/images/trunk_cache_split.png ; do
  printf "  %-46s " "$p"
  if [ -e "$p" ]; then echo "ok"; else echo "*** MISSING ***"; fail=$((fail+1)); fi
done

echo
echo "== ledger lines it cites"
for n in 221 224 246 259 261 282 284 312 325 327 329 334 339 343 347 358 359 374 376 377 378 389 392 397; do
  line=$(sed -n "${n}p" papers/byteflow-matrix.md 2>/dev/null)
  if [ -z "$line" ]; then echo "  :$n  *** OUT OF RANGE ***"; fail=$((fail+1)); fi
done
echo "  all cited ledger lines in range (nothing listed above = ok)"

echo
echo "== the 17 lines above are non-contiguous; spot-check the load-bearing ones"
for n in 246 327 259 347 377 378; do
  printf "  :%-4s " "$n"
  sed -n "${n}p" papers/byteflow-matrix.md | cut -c1-95 | sed 's/^/ /'
done

echo
echo "== figures it quotes, against the ledger"
for pair in "25\.83" "303\.58" "324\.36" "10,010" "19\.1" "6\.7" "20\.99" "17\.44" "11,?697"; do
  n=$(grep -cE "$pair" papers/byteflow-matrix.md 2>/dev/null | head -1)
  [ -z "$n" ] && n=0
  printf "  %-8s %s hits in ledger\n" "$pair" "$n"
done

echo
echo "== claims the document makes about absent sources"
for v in 107.27 96.35 106.52 100.17; do
  n=$(grep -cE "$v" papers/byteflow-matrix.md 2>/dev/null || echo 0)
  printf "  %-8s %s hits (must be 0 -- that is why table 3 was removed)\n" "$v" "$n"
done

echo
echo "== the two figures referenced by the paper exist and are non-trivial"
for f in docs/images/bytes_paradox.png docs/images/trunk_cache_split.png; do
  sz=$(stat -c %s "$f" 2>/dev/null || echo 0)
  printf "  %-38s %s bytes %s\n" "$f" "$sz" "$([ "$sz" -gt 10000 ] && echo ok || echo '*** suspiciously small ***')"
done

echo
echo "== v62 raw.tsv really has 12 readings"
printf "  lines: %s\n" "$(wc -l < reports/gateab_ab/v62_policy/raw.tsv 2>/dev/null || echo 0)"
sort -u reports/gateab_ab/v62_policy/raw.tsv 2>/dev/null | awk -F'\t' '{print "  " $2 $3 "  " $4}' | sort -u | sed 's/^/ /'

echo
[ $fail -eq 0 ] && echo "  ALL CITED PATHS RESOLVE" || echo "  $fail PROBLEM(S)"
exit $fail