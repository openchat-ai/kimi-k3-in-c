#!/bin/bash
set -u
# spec_run2: 长线全程跑 spec_amp_gates.sh (K=4/8, 1024-prompt, spec-amp)
# 依赖 /mnt/wsl/PHYSICALDRIVE2p7 已由主会话 wsl --mount 挂出; 这里做 bind-fallback 兜底
LOG=/mnt/f/kimi-k3-in-c/reports/spec_run2
mkdir -p "$LOG"
if [ ! -d /mnt/nvme/trunk_layers_out ]; then
  if [ -d /mnt/wsl/PHYSICALDRIVE2p7/trunk_layers_out ]; then
    mkdir -p /mnt/nvme
    mount --bind /mnt/wsl/PHYSICALDRIVE2p7 /mnt/nvme 2>/dev/null
    sleep 1
  fi
  if [ ! -d /mnt/nvme/trunk_layers_out ]; then
    echo "FATAL: no /mnt/nvme (P7 missing)" > "$LOG/rc.txt"
    exit 9
  fi
fi
cd /mnt/f/kimi-k3-in-c/reports || exit 9
echo "START $(date +%H:%M:%S) $(date +%s)" > "$LOG/rc.txt"
timeout -k 60 2700 bash spec_amp_gates.sh > "$LOG/run.log" 2>&1
echo "RC=$? $(date +%H:%M:%S) $(date +%s)" >> "$LOG/rc.txt"