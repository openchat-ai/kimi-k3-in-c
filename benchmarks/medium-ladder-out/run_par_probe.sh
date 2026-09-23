#!/bin/bash
cd /mnt/f/kimi-k3-in-c/benchmarks/medium-ladder-out
OFFS=$(cat /mnt/c/Users/Administrator/AppData/Local/Temp/opencode/rand_offs.txt)
./par_read /mnt/nvme/experts.l2 $OFFS