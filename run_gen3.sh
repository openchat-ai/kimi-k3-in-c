#!/bin/bash
cd /mnt/f/kimi-k3-in-c
rm -f reports/heat_auto_embed.log reports/heat_auto_embed.json
timeout 1700 ./bin/k3 /model \
  --trunk /mnt/nvme/trunk_layers_out \
  --l2 /mnt/nvme/experts.l2 \
  --embed-dir /mnt/nvme/embed \
  --preset auto --ids 1008 --gen 2 \
  --out reports/heat_auto_embed.json 2>&1 | tee reports/heat_auto_embed.log
echo "EXIT=$?"