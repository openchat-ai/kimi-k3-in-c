#!/bin/bash
# ab8: trunk resident in RAM (no per-token trunk sweep) on a 56 GB box.
# 5.4 GB is untouchable (embed+lm_head 4.7 + recurrent state 0.63), so ~51 GB is
# divisible between the trunk and the expert arena. 25/26 is the balance point:
#   trunk 25 GB = 41/93 layers resident -> trunk sweep 54.6*(52/93) = 30.5 GB/token
#   expert arena 26 GB = 1480 slots, 3x today's 17.7 GB -> expert traffic 22.9 -> ~18 GB
#   net per-token disk traffic 63 GB -> ~48 GB  (at 1010 MB/s that is the wall)
# Control: v7 (kio, group 0, no hold) = 112.69 s/tok with 13.6-17.7 GB arena.
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

LOG=/mnt/f/kimi-k3-in-c/reports/gateab_ab/v9_res25-$(date +%Y%m%d_%H%M%S)
mkdir -p "$LOG"
unset K3_NOKIO K3_L2_NATIVE
echo "[ab8] $LOG mode=kio (L2 group 0, no hold) + trunk 25GB resident / cache 26GB"
sync; echo 3 > /proc/sys/vm/drop_caches; sleep 2
/usr/bin/time -f "TIME_ELAPSED=%e" ./bin/k3 /model \
  --trunk /mnt/nvme/trunk_layers_out --embed-dir /mnt/nvme/embed \
  --trunk-gb 25 --cache-gb 26 \
  --ids 1008 --gen 8 --out "$LOG/ctrl.json" > "$LOG/ctrl.log" 2>&1
RC=$?
echo "EXIT=$RC load=$(cut -d' ' -f1-3 /proc/loadavg)"
{
  echo "--- v9_res25 (kio group 0, no hold, trunk 25GB resident / cache 26GB)"
  grep -aE "auto budget|explicit|trunk .* GB|expert cache|pinned .*/93|resident [0-9]+/|TRUE resident|s/token average|I/O share|experts, whole|phase2|pread\)|bind wall" "$LOG/ctrl.log" | tail -16
  grep -aE "^TIME_ELAPSED" "$LOG/ctrl.log"
  grep -aE "peak_rss_bytes|seconds_per_token|trunk_bytes_read|expert_bytes_read" "$LOG/ctrl.json"
} > "$LOG/summary.txt"
cat "$LOG/summary.txt"
echo "[ab8] end $(date +%T)"