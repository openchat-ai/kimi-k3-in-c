#!/bin/bash
# A/B: revert binary (kio zero-parking, l2 back to group 0). Expect ~81-82 (anchor 081).
set -u
echo "[ab3] start $(date +%T) load=$(cut -d' ' -f1-3 /proc/loadavg) nproc=$(grep -c ^processor /proc/cpuinfo)"

if ! mountpoint -q /mnt/nvme 2>/dev/null; then
  for i in /mnt/wsl/PHYSICALDRIVE2p7; do
    [ -d "$i" ] && { mkdir -p /mnt/nvme; mount --bind "$i" /mnt/nvme; break; }
  done
  mountpoint -q /mnt/nvme || { echo "[ab3] FATAL: nvme unavailable"; exit 9; }
fi

cd /mnt/f/kimi-k3-in-c
[ -x ./bin/k3 ] || { echo "[ab3] FATAL: ./bin/k3 missing"; exit 9; }
grep -aE "seconds_per_token" /mnt/f/kimi-k3-in-c/reports/gateab_ab/v0_repeat-*/ctrl.json >/dev/null || true

LOG=/mnt/f/kimi-k3-in-c/reports/gateab_ab/v2_revert-$(date +%Y%m%d_%H%M%S)
mkdir -p "$LOG"
unset K3_NOKIO
echo "[ab3] $LOG mode=kio(revert-zero-parking)"
sync; echo 3 > /proc/sys/vm/drop_caches; sleep 2
/usr/bin/time -f "TIME_ELAPSED=%e" ./bin/k3 /model \
  --trunk /mnt/nvme/trunk_layers_out --embed-dir /mnt/nvme/embed \
  --ids 1008 --gen 8 --out "$LOG/ctrl.json" > "$LOG/ctrl.log" 2>&1
RC=$?
echo "EXIT=$RC load=$(cut -d' ' -f1-3 /proc/loadavg)"
{
  echo "--- v2_revert (mode=kio revert)"
  grep -aE "auto budget|explicit budget|trunk .* GB|expert cache|pinned .*/93|s/token average|I/O share|experts, whole|parked on the expert gate|phase2|pread\)" "$LOG/ctrl.log" | tail -12
  grep -aE "^TIME_ELAPSED" "$LOG/ctrl.log"
  grep -aE "peak_rss_bytes|seconds_per_token" "$LOG/ctrl.json"
} > "$LOG/summary.txt"
cat "$LOG/summary.txt"
echo "[ab3] end $(date +%T)"