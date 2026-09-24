#!/bin/bash
set -u
L=/mnt/f/kimi-k3-in-c/reports/cap_sweep_20260924_144820/ctrl.log
echo "=== trunk-related lines (distinct) ==="
grep -aE "trunk" $L | sort -u | head -20
echo
echo "=== L1 layer lines sample (first 3, to see layer weight source) ==="
grep -aE "L1[ ]+needs|L1[ ]+read|L1[ ]+stream" $L | head -3
echo
echo "=== any 110.00 / 53.4 / 55.6 / packed mentions ==="
grep -aE "110\.00|53\.4|55\.6|packed|mxfp8|O_DIRECT|ring " $L | sort -u | head -10
echo done