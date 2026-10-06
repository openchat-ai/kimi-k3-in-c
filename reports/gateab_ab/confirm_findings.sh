#!/bin/bash
# Two audit findings to confirm before reporting them.
#   1. 20.99 GB -- the heat-vs-LRU figure the paper cites in 4.5 and the conclusion. A search of
#      the ledger found nothing, so either it is spelled differently or it has no source.
#   2. The paper says KV new keys decay "token1≈1483 -> token32≈24"; the ledger line that does
#      discuss the decay says "1472→1176→878→521" and "32 token 累计恰 = 11697". Check whether
#      1483 and 24 exist anywhere, and whether 1472 vs 1483 is the same figure miscited.
set -u
cd /mnt/f/kimi-k3-in-c
L=papers/byteflow-matrix.md

echo "== 1. 20.99 / heat 策略"
echo "  20.99 出现次数: $(grep -c '20\.99' "$L")"
echo "  20.9x 变体:"
grep -nE '20\.9[0-9]' "$L" | head -5 | cut -c1-140 | sed 's/^/     /'
echo "  heat 相关行:"
grep -niE 'heat' "$L" | head -8 | cut -c1-150 | sed 's/^/     /'
echo
echo "  4.5 节在论文里怎么写的:"
grep -nE '20\.99' "papers/论文-慢层只读一次原则.md" | cut -c1-160 | sed 's/^/     /'
echo
echo "== 2. KV 衰减序列"
echo "  1483 出现次数: $(grep -c '1483' "$L")"
grep -nE '1483' "$L" | head -4 | cut -c1-140 | sed 's/^/     /'
echo "  1472 出现次数: $(grep -c '1472' "$L")"
grep -nE '1472' "$L" | head -4 | cut -c1-140 | sed 's/^/     /'
echo "  token32≈24 的依据:"
grep -nE '=24|≈24|24\b' "$L" | grep -iE 'token|衰减' | head -5 | cut -c1-140 | sed 's/^/     /'
echo
echo "  台账里 KV 衰减的完整表述:"
sed -n '376p' "$L" | cut -c1-400 | sed 's/^/     /'