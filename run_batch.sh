#!/bin/bash
cd /mnt/f/kimi-k3-in-c
rm -f reports/batch_gen.log reports/batch_gen.json
timeout 800 ./bin/k3 /model \
  --trunk /mnt/nvme/trunk_layers_out \
  --l2 /mnt/nvme/experts.l2 \
  --embed-dir /mnt/nvme/embed \
  --preset auto \
  --batch-gen --gen 4 \
  --ids 1008 \
  --out reports/batch_gen.json 2>&1 | tee reports/batch_gen.log
echo "EXIT=$?"