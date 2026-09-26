#!/bin/bash
# ab8: trunk resident in RAM (no per-token trunk sweep) on a 60GB WSL box.
# Control: v4_native 124.68 s/tok, v4pf 128.69 | v4_native reads 77.5 GB/token
#   (trunk 54.6 + experts 22.9). 40 GB trunk = 65/93 layers resident -> trunk sweep
#   drops to 54.6*(28/93) = 16.4 GB/token; net per-token disk traffic ~56 GB
#   (trunk 16.4 + experts ~25 at 8 GB arena = 455 slots, TRUE hit slightly lower).
# Expect wall toward 60-80 if the trunk read was the serial half of the wall.
set -u
echo "[ab8] start $(date +%T) load=$(cut -d' ' -f1-3 /proc/loadavg) nproc=$(grep -c ^processor /proc/cpuinfo)"
grep -E 'MemTotal|MemAvailable' /proc/meminfo

if ! mountpoint -q /mnt/nvme 2>/dev/null; then
  for i in /mnt/wsl/PHYSICALDRIVE2p7; do
    [ -d "$i" ] && { mkdir -p /mnt/nvme; mount --bind "$i" /mnt/nvme; break; }
  done
  mountpoint -q /mnt/nvme || { echo "[ab8] FATAL: nvme unavailable"; exit 9; }
fi

cd /mnt/f/kimi-k3-in-c
[ -x ./bin/k3 ] || { echo "[ab8] FATAL: ./bin/k3 missing"; exit 9; }

LOG=/mnt/f/kimi-k3-in-c/reports/gateab_ab/v4res-$(date +%Y%m%d_%H%M%S)
mkdir -p "$LOG"
unset K3_NOKIO
export K3_L2_NATIVE=1
echo "[ab8] $LOG mode=all-native + trunk-resident 40GB / cache 8GB"
sync; echo 3 > /proc/sys/vm/drop_caches; sleep 2
/usr/bin/time -f "TIME_ELAPSED=%e" ./bin/k3 /model \
  --trunk /mnt/nvme/trunk_layers_out --embed-dir /mnt/nvme/embed \
  --trunk-gb 40 --cache-gb 8 \
  --ids 1008 --gen 8 --out "$LOG/ctrl.json" > "$LOG/ctrl.log" 2>&1
RC=$?
unset K3_L2_NATIVE
echo "EXIT=$RC load=$(cut -d' ' -f1-3 /proc/loadavg)"
{
  echo "--- v4res (all-native + trunk 40GB resident / cache 8GB)"
  grep -aE "auto budget|explicit budget|trunk .* GB|expert cache|pinned .*/93|resident|s/token average|I/O share|experts, whole|phase2|pread\)" "$LOG/ctrl.log" | tail -16
  grep -aE "^TIME_ELAPSED" "$LOG/ctrl.log"
  grep -aE "peak_rss_bytes|seconds_per_token|trunk_bytes_read|expert_bytes_read" "$LOG/ctrl.json"
} > "$LOG/summary.txt"
cat "$LOG/summary.txt"
echo "[ab8] end $(date +%T)"