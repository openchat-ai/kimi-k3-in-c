#!/bin/bash
# Background long-horizon A/B (gen 8). Self-contained: ensure /mnt/nvme, run both legs.
set -u
echo "[bg] start $(date +%T)"

# ensure /mnt/nvme is mounted (Start-Process spawns a fresh wsl session)
if ! mountpoint -q /mnt/nvme 2>/dev/null; then
  echo "[bg] nvme not mounted, binding from wsl mount"
  for i in /mnt/wsl/PHYSICALDRIVE2p7 /mnt/wsl/PHYSICALDRIVE2p7; do
    [ -d "$i" ] && { mkdir -p /mnt/nvme; mount --bind "$i" /mnt/nvme; break; }
  done
  mountpoint -q /mnt/nvme || { echo "[bg] FATAL: nvme unavailable"; exit 9; }
fi

LOG=/mnt/f/kimi-k3-in-c/reports/lb_lh2_$(date +%Y%m%d_%H%M%S)
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

run a ""
run b "--layer-bundle"

echo "[bg] ALL_DONE"
{
  for x in a b; do
    echo "--- $x"
    grep -aE "pinned .*/93|TRUE resident|s/token average|read .* GB in" "$LOG/$x.log" | tail -5
    awk '/^ *[0-9]+ +[0-9]+/{printf "tok %s %s s\n",$2,$3}' "$LOG/$x.log" | tail -10
  done
} > "$LOG/summary.txt"
cat "$LOG/summary.txt"
echo "[bg] end $(date +%T)"