#!/bin/bash
# Dry-run forecast: what does the layer-bundle planner predict for C (GB/token)
# on the same L2/trunk the repro just measured? Compare C vs measured 24 GB/token.
set -u
cd /mnt/f/kimi-k3-in-c
LOG=reports/lb_dryrun_$(date +%Y%m%d_%H%M%S)
if ! mountpoint -q /mnt/nvme 2>/dev/null; then
  echo "FATAL: nvme must be mounted (mountpoint /mnt/nvme)" >&2
  exit 9
fi
mkdir -p "$LOG"
echo "LOGDIR=$LOG"
./bin/k3 /model \
  --trunk /mnt/nvme/trunk_layers_out \
  --l2 /mnt/nvme/experts.l2 \
  --ids 1008 --gen 8 \
  --layer-bundle --dry-run \
  > "$LOG/dryrun.log" 2>&1
echo "EXIT=$?"
echo "==== dryrun.log ===="
cat "$LOG/dryrun.log"
echo "==== end ===="