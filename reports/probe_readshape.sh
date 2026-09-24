#!/bin/bash
# shape probe: sizes the expert-read lever (16thr-rand current vs 1thr-sorted/seq)
set -u
echo "[bg] start $(date +%T)"
if ! mountpoint -q /mnt/nvme 2>/dev/null; then
  echo "[bg] nvme not mounted, binding from wsl mount"
  for i in /mnt/wsl/PHYSICALDRIVE2p7; do
    [ -d "$i" ] && { mkdir -p /mnt/nvme; mount --bind "$i" /mnt/nvme; break; }
  done
  mountpoint -q /mnt/nvme || { echo "[bg] FATAL: nvme unavailable"; exit 9; }
fi
LOG=/mnt/f/kimi-k3-in-c/reports/probe_readshape_$(date +%Y%m%d_%H%M%S)
mkdir -p "$LOG"
python3 -u /mnt/f/kimi-k3-in-c/reports/probe_readshape.py 2>&1 | tee "$LOG/result.txt"
echo "[bg] end $(date +%T)"