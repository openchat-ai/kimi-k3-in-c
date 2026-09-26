#!/bin/bash
# A/B: COLD-DISK control arm (v2 semantics). WSL was shutdown at 14:59 for ~6min cooldown.
# Same binary as v3 (default, no K3_L2_NATIVE, no K3_NOKIO) = v2_revert semantics (kio L2, zero parking).
# Compare vs v2_revert-20260926_141618 111.56s/tok (hot). Cold either restores ~81-90 (heat decay) or stays ~110 (code).
set -u
echo "[ab5] start $(date +%T) load=$(cut -d' ' -f1-3 /proc/loadavg)"

if ! mountpoint -q /mnt/nvme 2>/dev/null; then
  for i in /mnt/wsl/PHYSICALDRIVE2p7; do
    [ -d "$i" ] && { mkdir -p /mnt/nvme; mount --bind "$i" /mnt/nvme; break; }
  done
  mountpoint -q /mnt/nvme || { echo "[ab5] FATAL: nvme unavailable"; exit 9; }
fi

cd /mnt/f/kimi-k3-in-c
[ -x ./bin/k3 ] || { echo "[ab5] FATAL: ./bin/k3 missing"; exit 9; }

LOG=/mnt/f/kimi-k3-in-c/reports/gateab_ab/v2_cold-$(date +%Y%m%d_%H%M%S)
mkdir -p "$LOG"
unset K3_NOKIO K3_L2_NATIVE
echo "[ab5] $LOG mode=v2-semantics COLD disk (VM restarted 14:59)"
sync; echo 3 > /proc/sys/vm/drop_caches; sleep 2
/usr/bin/time -f "TIME_ELAPSED=%e" ./bin/k3 /model \
  --trunk /mnt/nvme/trunk_layers_out --embed-dir /mnt/nvme/embed \
  --ids 1008 --gen 8 --out "$LOG/ctrl.json" > "$LOG/ctrl.log" 2>&1
RC=$?
echo "EXIT=$RC load=$(cut -d' ' -f1-3 /proc/loadavg)"
{
  echo "--- v2_cold (mode=v2-semantics, COLD disk)"
  grep -aE "auto budget|trunk .* GB|expert cache|pinned .*/93|s/token average|I/O share|experts, whole|parked on the expert gate|phase2|pread\)" "$LOG/ctrl.log" | tail -12
  grep -aE "^TIME_ELAPSED" "$LOG/ctrl.log"
  grep -aE "peak_rss_bytes|seconds_per_token" "$LOG/ctrl.json"
} > "$LOG/summary.txt"
cat "$LOG/summary.txt"
echo "[ab5] end $(date +%T)"