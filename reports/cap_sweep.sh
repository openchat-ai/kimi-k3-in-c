#!/bin/bash
# v2 cap-sweep: prefetch depth pinned at 1 (the only survivable depth from the v1 sweep),
# per-layer cap 0/4/8. Same-session depth-0 control for an exact A/B on today's L2.
set -u
echo "[bg] start $(date +%T)"

if ! mountpoint -q /mnt/nvme 2>/dev/null; then
  echo "[bg] nvme not mounted, binding from wsl mount"
  for i in /mnt/wsl/PHYSICALDRIVE2p7 /mnt/wsl/PHYSICALDRIVE2p7; do
    [ -d "$i" ] && { mkdir -p /mnt/nvme; mount --bind "$i" /mnt/nvme; break; }
  done
  mountpoint -q /mnt/nvme || { echo "[bg] FATAL: nvme unavailable"; exit 9; }
fi

LOG=/mnt/f/kimi-k3-in-c/reports/cap_sweep_$(date +%Y%m%d_%H%M%S)
mkdir -p "$LOG"
echo "[bg] LOGDIR=$LOG"

cd /mnt/f/kimi-k3-in-c
drop() { sync; echo 3 > /proc/sys/vm/drop_caches; sleep 2; }
run() {
  drop
  /usr/bin/time -f "TIME_ELAPSED=%e" ./bin/k3 /model \
    --trunk /mnt/nvme/trunk_layers_out --embed-dir /mnt/nvme/embed \
    --ids 1008 --gen 8 $2 --out "$LOG/$1.json" > "$LOG/$1.log" 2>&1
  echo "[bg] $1 EXIT=$?"
}

run ctrl ""              # depth 0: same-session no-prefetch control
run cp4  "--prefetch-depth 1 --prefetch-cap 4"
run cp8  "--prefetch-depth 1 --prefetch-cap 8"

echo "[bg] ALL_DONE"
{
  echo "--- cap sweep (b leg, depth fixed 1)"
  for k in ctrl cp4 cp8; do
    echo "=== $k ==="
    grep -aE "pinned .*/93|TRUE resident|s/token average|prefetch  |I/O share|experts, whole" "$LOG/$k.log" | tail -7
    grep -aE "^TIME_ELAPSED" "$LOG/$k.log"
  done
} > "$LOG/summary.txt"
cat "$LOG/summary.txt"
echo "[bg] end $(date +%T)"