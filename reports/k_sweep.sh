#!/bin/bash
# Background k-sweep of the async expert prefetch-ahead on the b leg (--layer-bundle).
# Same wall protocol as lb_b_repro.sh: page-cache drop per run, ids=1008 hot set on the
# already-warm L2 (sequential same-set runs keep it hot), THE AO/BO baseline untouched.
set -u
echo "[bg] start $(date +%T)"

if ! mountpoint -q /mnt/nvme 2>/dev/null; then
  echo "[bg] nvme not mounted, binding from wsl mount"
  for i in /mnt/wsl/PHYSICALDRIVE2p7 /mnt/wsl/PHYSICALDRIVE2p7; do
    [ -d "$i" ] && { mkdir -p /mnt/nvme; mount --bind "$i" /mnt/nvme; break; }
  done
  mountpoint -q /mnt/nvme || { echo "[bg] FATAL: nvme unavailable"; exit 9; }
fi

LOG=/mnt/f/kimi-k3-in-c/reports/k_sweep_$(date +%Y%m%d_%H%M%S)
mkdir -p "$LOG"
echo "[bg] LOGDIR=$LOG"

cd /mnt/f/kimi-k3-in-c
drop() { sync; echo 3 > /proc/sys/vm/drop_caches; sleep 2; }
run() {
  local k=$1
  drop
  /usr/bin/time -f "TIME_ELAPSED=%e" ./bin/k3 /model \
    --trunk /mnt/nvme/trunk_layers_out --embed-dir /mnt/nvme/embed \
    --ids 1008 --gen 8 ${2:-} --out "$LOG/k$k.json" > "$LOG/k$k.log" 2>&1
  echo "[bg] k$k EXIT=$?"
}

run 0
run 1 "--prefetch-depth 1"
run 2 "--prefetch-depth 2"
run 4 "--prefetch-depth 4"

echo "[bg] ALL_DONE"
{
  echo "--- k-sweep (b leg)"
  for k in 0 1 2 4; do
    echo "=== k$k ==="
    grep -aE "pinned .*/93|TRUE resident|s/token average|prefetch  |I/O share" "$LOG/k$k.log" | tail -6
    grep -aE "^TIME_ELAPSED" "$LOG/k$k.log"
  done
} > "$LOG/summary.txt"
cat "$LOG/summary.txt"
echo "[bg] end $(date +%T)"