#!/bin/bash
set -e
PROBE=/mnt/f/kimi-k3-in-c/benchmarks/medium-ladder-out/expert_pread
OFFS=$(cat /mnt/c/Users/Administrator/AppData/Local/Temp/opencode/rand_offs.txt)
echo "=== random O_DIRECT cold, 1470x17.55MB single-thread (median of 3) ==="
$PROBE /mnt/nvme/experts.l2 $OFFS
echo done