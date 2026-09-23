#!/bin/bash
# 93L gen3 + cache trace: quantify the cross-token stable hot-expert set H.
cd /mnt/f/kimi-k3-in-c
rm -f reports/heat_probe.log reports/heat_probe.json reports/heat_probe_trace/expert_hist.json
mkdir -p reports/heat_probe_trace
timeout 1500 ./bin/k3 /model \
  --trunk /mnt/nvme/trunk_layers_out \
  --l2 /mnt/nvme/experts.l2 \
  --embed-dir /mnt/nvme/embed \
  --preset auto \
  --gen 3 \
  --ids 1008 \
  --out reports/heat_probe.json \
  --dump-cache-trace reports/heat_probe_trace 2>&1 | tee reports/heat_probe.log
echo "EXIT=$?"