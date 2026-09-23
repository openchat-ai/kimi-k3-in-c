#!/bin/bash
cd /mnt/f/kimi-k3-in-c
rm -f reports/heat_manual.log reports/heat_manual.json
timeout 500 ./bin/k3 /model \
  --trunk /mnt/nvme/trunk_layers_out \
  --l2 /mnt/nvme/experts.l2 \
  --embed-dir /mnt/nvme/embed \
  --cache-gb 16 --trunk-gb 6 \
  --ids 1008 --gen 1 \
  --out reports/heat_manual.json 2>&1 | tee reports/heat_manual.log
echo "EXIT=$?"