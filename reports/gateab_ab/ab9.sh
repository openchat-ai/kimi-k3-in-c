#!/bin/bash
# ab9 / v5: L2 hit reads back in group 1 (61cf381 shape) + st on the shared kio queue.
# No K3_L2_NATIVE: st.kio = &g_io, so trunk and experts share one K3IO (tier 0 / per-shard
# tiers) exactly as in 081, whose I/O share was 144.1% (trunk+experts interleaved).
# phase2_hold stays unmounted (run.c gate), so active_group never flips and the
# deadlock chain of 2e220d9 cannot form; its depth-counted hold remains in place.
# Control: 081=81.28 (morning, same shape, pre-deadlock-fix binary) | v2_revert=111.56
# (same code, but L2 hits in group 0) | v4 native=124.68.
set -u
echo "[ab9] start $(date +%T) load=$(cut -d' ' -f1-3 /proc/loadavg) nproc=$(grep -c ^processor /proc/cpuinfo)"

if ! mountpoint -q /mnt/nvme 2>/dev/null; then
  for i in /mnt/wsl/PHYSICALDRIVE2p7; do
    [ -d "$i" ] && { mkdir -p /mnt/nvme; mount --bind "$i" /mnt/nvme; break; }
  done
  mountpoint -q /mnt/nvme || { echo "[ab9] FATAL: nvme unavailable"; exit 9; }
fi

cd /mnt/f/kimi-k3-in-c
[ -x ./bin/k3 ] || { echo "[ab9] FATAL: ./bin/k3 missing"; exit 9; }

LOG=/mnt/f/kimi-k3-in-c/reports/gateab_ab/v5_l2g1-$(date +%Y%m%d_%H%M%S)
mkdir -p "$LOG"
unset K3_NOKIO K3_L2_NATIVE
echo "[ab9] $LOG mode=kio-unified (L2 hits in group 1, st via g_io, no hold mounted)"
sync; echo 3 > /proc/sys/vm/drop_caches; sleep 2
/usr/bin/time -f "TIME_ELAPSED=%e" ./bin/k3 /model \
  --trunk /mnt/nvme/trunk_layers_out --embed-dir /mnt/nvme/embed \
  --ids 1008 --gen 8 --out "$LOG/ctrl.json" > "$LOG/ctrl.log" 2>&1
RC=$?
echo "EXIT=$RC load=$(cut -d' ' -f1-3 /proc/loadavg)"
{
  echo "--- v5_l2g1 (kio unified, L2 hits group 1, no phase2 hold)"
  grep -aE "auto budget|trunk .* GB|expert cache|pinned .*/93|TRUE resident|s/token average|I/O share|experts, whole|phase2|pread\)|parked" "$LOG/ctrl.log" | tail -14
  grep -aE "^TIME_ELAPSED" "$LOG/ctrl.log"
  grep -aE "peak_rss_bytes|seconds_per_token|trunk_bytes_read|expert_bytes_read" "$LOG/ctrl.json"
} > "$LOG/summary.txt"
cat "$LOG/summary.txt"
echo "[ab9] end $(date +%T)"