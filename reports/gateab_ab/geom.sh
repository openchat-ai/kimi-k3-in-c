#!/bin/bash
# Print the engine's exact L2 geometry. One fast run, no measurement -- this only reads
# the startup line so the storage probe can stop guessing the unit size.
set -u
cd /mnt/f/kimi-k3-in-c
unset K3_TRACE K3_NOKIO K3_L2_NATIVE
./bin/k3 /model \
  --trunk /mnt/nvme/trunk_layers_out --embed-dir /mnt/nvme/embed \
  --l2 /mnt/nvme/experts.l2 --trunk-gb 32 --cache-gb 15 \
  --ids 1008 --gen 0 --out /tmp/geom.json 2>&1 | grep -aE "expert L2|expert cache" | sed 's/^/   /'
