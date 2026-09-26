#!/bin/bash
for sz in 1048576 2097152 4194304; do
  echo "== C=0.30 per_slot=$sz"
  timeout 120 /root/probe_pipe /mnt/nvme/trunk_layers_out/layer_000.bin 0.30 "$sz" 12
done
echo ALL-DONE