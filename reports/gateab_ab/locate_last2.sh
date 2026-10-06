#!/bin/bash
# Two figures in table A.1 whose replacement line numbers are not yet located: the 84 MB/s
# slow-disk characterisation attributed to D-state (:286, :289 in the paper), and the
# steady-tail 27 GB / 16 tokens (:443). Everything else has a verified location.
set -u
cd /mnt/f/kimi-k3-in-c
L=papers/byteflow-matrix.md

echo "== 84 MB/s 与 D-state"
grep -nE 'D-state|D state' "$L" | head -6 | cut -c1-150 | sed 's/^/   /'
echo "  -- 84 附近:"
grep -nE '\b84\b|8[34]\.?[0-9]* ?MB/s|60 ?MB/s|68 ?MB/s' "$L" | head -8 | cut -c1-140 | sed 's/^/   /'
echo
echo "== 稳态尾段 27 GB / 16 词元"
grep -nE '27 ?GB|27\.0|尾段|后 ?16 ?词元|16 ?词元' "$L" | head -8 | cut -c1-145 | sed 's/^/   /'
echo
echo "== 205 GB（86 GB 占42% 的分母）"
grep -nE '205' "$L" | head -4 | cut -c1-140 | sed 's/^/   /'