#!/bin/bash
# A/B: v3 native L2 expert read (K3_L2_NATIVE=1, l2.kio=NULL, zero parking, group0).
# Control: v2_revert-20260926_141618 = 111.56s/tok (kio L2). Target: ~100-102 (v1 native anchor 1109MB/s).
set -u
echo "[ab4] start $(date +%T) load=$(cut -d' ' -f1-3 /proc/loadavg) nproc=$(grep -c ^processor /proc/cpuinfo)"

if ! mountpoint -q /mnt/nvme 2>/dev/null; then
  for i in /mnt/wsl/PHYSICALDRIVE2p7; do
    [ -d "$i" ] && { mkdir -p /mnt/nvme; mount --bind "$i" /mnt/nvme; break; }
  done
  mountpoint -q /mnt/nvme || { echo "[ab4] FATAL: nvme unavailable"; exit 9; }
fi

cd /mnt/f/kimi-k3-in-c
[ -x ./bin/k3 ] || { echo "[ab4] FATAL: ./bin/k3 missing"; exit 9; }

LOG=/mnt/f/kimi-k3-in-c/reports/gateab_ab/v3_native-$(date +%Y%m%d_%H%M%S)
mkdir -p "$LOG"
unset K3_NOKIO
export K3_L2_NATIVE=1
echo "[ab4] $LOG mode=l2-native (kio L2 OFF, zero parking)"
sync; echo 3 > /proc/sys/vm/drop_caches; sleep 2
/usr/bin/time -f "TIME_ELAPSED=%e" ./bin/k3 /model \
  --trunk /mnt/nvme/trunk_layers_out --embed-dir /mnt/nvme/embed \
  --ids 1008 --gen 8 --out "$LOG/ctrl.json" > "$LOG/ctrl.log" 2>&1
RC=$?
unset K3_L2_NATIVE
echo "EXIT=$RC load=$(cut -d' ' -f1-3 /proc/loadavg)"
{
  echo "--- v3_native (mode=l2-native)"
  grep -aE "auto budget|explicit budget|trunk .* GB|expert cache|pinned .*/93|s/token average|I/O share|experts, whole|parked on the expert gate|phase2|pread\)" "$LOG/ctrl.log" | tail -12
  grep -aE "^TIME_ELAPSED" "$LOG/ctrl.log"
  grep -aE "peak_rss_bytes|seconds_per_token" "$LOG/ctrl.json"
} > "$LOG/summary.txt"
cat "$LOG/summary.txt"
echo "[ab4] end $(date +%T)"