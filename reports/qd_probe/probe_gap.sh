#!/usr/bin/env bash
set -u
OUT=/mnt/f/kimi-k3-in-c/reports/qd_probe
mkdir -p "$OUT"
LOG="$OUT/probe_gap_$(date +%Y%m%d_%H%M%S).log"

if [ ! -f /mnt/nvme/experts.l2 ]; then
    mkdir -p /mnt/wsl/PHYSICALDRIVE2p7 /mnt/nvme
    if [ -f /mnt/wsl/PHYSICALDRIVE2p7/experts.l2 ]; then
        mount --bind /mnt/wsl/PHYSICALDRIVE2p7 /mnt/nvme 2>/dev/null
    fi
fi
[ -f /mnt/nvme/experts.l2 ] || { echo "NVME-NOT-ATTACHED"; exit 9; }

# ---- wait for ab2 (gate A/B) to finish: must not disturb that measurement ----
AB=/mnt/f/kimi-k3-in-c/reports/gateab_ab
stable=0
echo "waiting for ab2 to complete ..." > "$LOG"
while :; do
    if pgrep -x k3 >/dev/null 2>&1; then
        stable=0
    else
        n=$(ls -d "$AB"/v[01]_* 2>/dev/null | wc -l)
        if [ "$n" -ge 2 ]; then stable=$((stable + 1)); else stable=0; fi
        [ "$stable" -ge 3 ] && break
    fi
    sleep 6
done
echo "ab2 done (stable), settling 10s" >> "$LOG"
sleep 10

echo "== engwave probe start $(date) ==" >> "$LOG"
uname -r >> "$LOG"
gcc -O2 -pthread -o "$OUT/nvmebench" /mnt/f/kimi-k3-in-c/reports/nvme_bench/bench.c 2>>"$LOG" || { echo "GCC-FAIL" >> "$LOG"; exit 8; }
cd "$OUT"

# engine shape: 16 threads, 16 slots/wave, 93 layers; sweep the compute-gap
for GAP in 0 25 50 100 250 500; do
  echo "== engwave gap=${GAP}ms nthr=16 spw=16 nwaves=93 ==" >> "$LOG"
  ./nvmebench engwave 16 16 "$GAP" 93 2>&1 | tee -a "$LOG"
done
# slots-per-wave sweep at gap=100ms (deeper per-wave queues)
for SPW in 8 32 64; do
  echo "== engwave gap=100ms nthr=16 spw=${SPW} nwaves=93 ==" >> "$LOG"
  ./nvmebench engwave 16 "$SPW" 100 93 2>&1 | tee -a "$LOG"
done
echo "== done $(date) ==" >> "$LOG"