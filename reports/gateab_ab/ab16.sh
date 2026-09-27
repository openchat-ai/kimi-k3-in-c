#!/bin/bash
# ab16: the 2026-09-26 08:59 binary (stash@{0}:bin/k3, the one behind the 82.99 run)
# under the 081 memory layout (trunk 6 GB + cache 13.6 GB), on today's 56 GB box.
# This is the only test that separates "the binary differed" from "the box differed":
# no source change, just a different executable. Run k3_0859 and bin/k3 back to back
# with identical args so the pair is directly comparable.
set -u
echo "[ab16] start $(date +%T) load=$(cut -d' ' -f1-3 /proc/loadavg) mem=$(awk '/MemTotal/{printf "%.1fGB", $2/1048576}' /proc/meminfo)"
if ! mountpoint -q /mnt/nvme 2>/dev/null; then
  mount /dev/sde7 /mnt/nvme 2>/dev/null || { echo "[ab16] FATAL nvme"; exit 9; }
fi
cd /mnt/f/kimi-k3-in-c
[ -x /root/k3_0859 ] || { echo "[ab16] FATAL: /root/k3_0859 missing"; exit 9; }
LOG=/mnt/f/kimi-k3-in-c/reports/gateab_ab/v16_oldbin-$(date +%Y%m%d_%H%M%S)
mkdir -p "$LOG"
unset K3_NOKIO K3_L2_NATIVE K3_IO_NW0
echo "[ab16] $LOG binary=/root/k3_0859 (2026-09-26 08:59) trunk 6GB / cache 13.6GB (081 layout)"
sync; echo 3 > /proc/sys/vm/drop_caches; sleep 2
/usr/bin/time -f "TIME_ELAPSED=%e" /root/k3_0859 /model \
  --trunk /mnt/nvme/trunk_layers_out --embed-dir /mnt/nvme/embed \
  --trunk-gb 6 --cache-gb 13.6 \
  --ids 1008 --gen 8 --out "$LOG/ctrl.json" > "$LOG/ctrl.log" 2>&1
RC=$?
echo "EXIT=$RC"
{
  echo "--- v16_oldbin (2026-09-26 08:59 binary, trunk 6GB / cache 13.6GB)"
  grep -aE "auto budget|explicit|trunk .* GB|expert cache|pinned .*/93|TRUE resident|s/token average|I/O share|experts, whole|phase2|pread\)|bind wall" "$LOG/ctrl.log" | tail -14
  grep -aE "^TIME_ELAPSED" "$LOG/ctrl.log"
  grep -aE "seconds_per_token|trunk_bytes_read|expert_bytes_read|peak_rss_bytes" "$LOG/ctrl.json"
} > "$LOG/summary.txt"
cat "$LOG/summary.txt"
echo "[ab16] end $(date +%T)"