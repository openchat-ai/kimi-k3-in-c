#!/bin/bash
# A/B: v4 native BOTH L2-hit AND expert-miss (st.kio=NULL via K3_L2_NATIVE).
# st path = native pread (k3_st.c:487/517); l2 hit single-slot pread too.
# Control v2_revert 111.56 (kio both) | v1 nokio anchor 102.04 (native both, no trunk park)
# Target when disk idle: ~102-105; signal = I/O share back toward 100%+ (overlap).
set -u
echo "[ab6] start $(date +%T) load=$(cut -d' ' -f1-3 /proc/loadavg) nproc=$(grep -c ^processor /proc/cpuinfo)"

if ! mountpoint -q /mnt/nvme 2>/dev/null; then
  for i in /mnt/wsl/PHYSICALDRIVE2p7; do
    [ -d "$i" ] && { mkdir -p /mnt/nvme; mount --bind "$i" /mnt/nvme; break; }
  done
  mountpoint -q /mnt/nvme || { echo "[ab6] FATAL: nvme unavailable"; exit 9; }
fi

cd /mnt/f/kimi-k3-in-c
[ -x ./bin/k3 ] || { echo "[ab6] FATAL: ./bin/k3 missing"; exit 9; }

LOG=/mnt/f/kimi-k3-in-c/reports/gateab_ab/v4_native-$(date +%Y%m%d_%H%M%S)
mkdir -p "$LOG"
unset K3_NOKIO
export K3_L2_NATIVE=1
echo "[ab6] $LOG mode=all-native (l2+st kio OFF, zero parking)"
sync; echo 3 > /proc/sys/vm/drop_caches; sleep 2
/usr/bin/time -f "TIME_ELAPSED=%e" ./bin/k3 /model \
  --trunk /mnt/nvme/trunk_layers_out --embed-dir /mnt/nvme/embed \
  --ids 1008 --gen 8 --out "$LOG/ctrl.json" > "$LOG/ctrl.log" 2>&1
RC=$?
unset K3_L2_NATIVE
echo "EXIT=$RC load=$(cut -d' ' -f1-3 /proc/loadavg)"
{
  echo "--- v4_native (mode=all-native l2+st)"
  grep -aE "auto budget|explicit budget|trunk .* GB|expert cache|pinned .*/93|s/token average|I/O share|experts, whole|phase2|pread\)" "$LOG/ctrl.log" | tail -12
  grep -aE "^TIME_ELAPSED" "$LOG/ctrl.log"
  grep -aE "peak_rss_bytes|seconds_per_token" "$LOG/ctrl.json"
} > "$LOG/summary.txt"
cat "$LOG/summary.txt"
echo "[ab6] end $(date +%T)"