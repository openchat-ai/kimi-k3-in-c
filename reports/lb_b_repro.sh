#!/bin/bash
# Background b-leg reproduction on the already a-warmed L2. Verify 86.92 s/token stability.
set -u
echo "[bg] start $(date +%T)"

if ! mountpoint -q /mnt/nvme 2>/dev/null; then
  echo "[bg] nvme not mounted, binding from wsl mount"
  for i in /mnt/wsl/PHYSICALDRIVE2p7 /mnt/wsl/PHYSICALDRIVE2p7; do
    [ -d "$i" ] && { mkdir -p /mnt/nvme; mount --bind "$i" /mnt/nvme; break; }
  done
  mountpoint -q /mnt/nvme || { echo "[bg] FATAL: nvme unavailable"; exit 9; }
fi

LOG=/mnt/f/kimi-k3-in-c/reports/lb_b_repro_$(date +%Y%m%d_%H%M%S)
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

run b "--layer-bundle"

echo "[bg] ALL_DONE"
{
  echo "--- b"
  grep -aE "pinned .*/93|TRUE resident|s/token average|read .* GB in" "$LOG/b.log" | tail -5
  awk '/^ *[0-9]+ +[0-9]+/{printf "tok %s %s s\n",$2,$3}' "$LOG/b.log" | tail -10
} > "$LOG/summary.txt"
cat "$LOG/summary.txt"
echo "[bg] end $(date +%T)"