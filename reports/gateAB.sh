#!/bin/bash
# gate A/B: L2-hit bursts now park the trunk GROUP via k3_io_set_active (kio path),
# or via the legacy gate when K3_NOKIO=1. Single 8-token k0 control run, same CLI.
set -u
echo "[bg] start $(date +%T)"

if ! mountpoint -q /mnt/nvme 2>/dev/null; then
  for i in /mnt/wsl/PHYSICALDRIVE2p7; do
    [ -d "$i" ] && { mkdir -p /mnt/nvme; mount --bind "$i" /mnt/nvme; break; }
  done
  mountpoint -q /mnt/nvme || { echo "[bg] FATAL: nvme unavailable"; exit 9; }
fi

LOG=/mnt/f/kimi-k3-in-c/reports/gateAB_$(date +%Y%m%d_%H%M%S)
mkdir -p "$LOG"
echo "[bg] LOGDIR=$LOG"

cd /mnt/f/kimi-k3-in-c
sync; echo 3 > /proc/sys/vm/drop_caches; sleep 2
if [ -n "${K3_NOKIO:-}" ]; then
  echo "[bg] K3_NOKIO=$K3_NOKIO (non-kio gate path)"
else
  unset K3_NOKIO
  echo "[bg] K3_NOKIO unset -> kio enabled (group switching)"
fi
/usr/bin/time -f "TIME_ELAPSED=%e" ./bin/k3 /model \
  --trunk /mnt/nvme/trunk_layers_out --embed-dir /mnt/nvme/embed \
  --ids 1008 --gen 8 --out "$LOG/ctrl.json" > "$LOG/ctrl.log" 2>&1
echo "[bg] ctrl EXIT=$?"

{
  echo "--- gate A/B (kio respects gate + L2-hit gated)"
  grep -aE "pinned .*/93|TRUE resident|s/token average|I/O share|experts, whole|parked on the expert gate|pread\)|phase2" "$LOG/ctrl.log" | tail -10
  grep -aE "^TIME_ELAPSED" "$LOG/ctrl.log"
} > "$LOG/summary.txt"
cat "$LOG/summary.txt"
echo "[bg] end $(date +%T)"