#!/bin/bash
# ab7: v4 native BOTH paths + async expert prefetch-ahead (--prefetch-depth 1).
# Hypothesis (081 vs v4 forensics): the 43 s/tok gap is expert-miss reads being
# synchronous in v4 (serialized against trunk stream) instead of overlapping.
# prefetch reader thread issues layer L+depth's expert reads while main thread
# computes L -> read time hides inside compute wall. Expect I/O share > 100% again
# and wall toward 85-100 (v1=102, 081=81.3, v4-no-prefetch=124.7).
set -u
echo "[ab7] start $(date +%T) load=$(cut -d' ' -f1-3 /proc/loadavg) nproc=$(grep -c ^processor /proc/cpuinfo)"

if ! mountpoint -q /mnt/nvme 2>/dev/null; then
  for i in /mnt/wsl/PHYSICALDRIVE2p7; do
    [ -d "$i" ] && { mkdir -p /mnt/nvme; mount --bind "$i" /mnt/nvme; break; }
  done
  mountpoint -q /mnt/nvme || { echo "[ab7] FATAL: nvme unavailable"; exit 9; }
fi

cd /mnt/f/kimi-k3-in-c
[ -x ./bin/k3 ] || { echo "[ab7] FATAL: ./bin/k3 missing"; exit 9; }

LOG=/mnt/f/kimi-k3-in-c/reports/gateab_ab/v4pf-$(date +%Y%m%d_%H%M%S)
mkdir -p "$LOG"
unset K3_NOKIO
export K3_L2_NATIVE=1
echo "[ab7] $LOG mode=all-native + prefetch-depth 1"
sync; echo 3 > /proc/sys/vm/drop_caches; sleep 2
/usr/bin/time -f "TIME_ELAPSED=%e" ./bin/k3 /model \
  --trunk /mnt/nvme/trunk_layers_out --embed-dir /mnt/nvme/embed \
  --prefetch-depth 1 \
  --ids 1008 --gen 8 --out "$LOG/ctrl.json" > "$LOG/ctrl.log" 2>&1
RC=$?
unset K3_L2_NATIVE
echo "EXIT=$RC load=$(cut -d' ' -f1-3 /proc/loadavg)"
{
  echo "--- v4pf (all-native + prefetch-depth 1)"
  grep -aE "auto budget|explicit budget|trunk .* GB|expert cache|pinned .*/93|s/token average|I/O share|experts, whole|phase2|pread\)|prefetch" "$LOG/ctrl.log" | tail -14
  grep -aE "^TIME_ELAPSED" "$LOG/ctrl.log"
  grep -aE "peak_rss_bytes|seconds_per_token" "$LOG/ctrl.json"
} > "$LOG/summary.txt"
cat "$LOG/summary.txt"
echo "[ab7] end $(date +%T)"