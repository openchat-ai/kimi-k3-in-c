#!/usr/bin/env bash
set -u
T0=$(date +%s)
OUT=/mnt/f/kimi-k3-in-c/reports/nvme_bench
[ -d /mnt/f/kimi-k3-in-c/reports ] || { echo "F-DRIVE-MISSING"; exit 3; }
[ -f /mnt/nvme/experts.l2 ] || { echo "NVME-NOT-ATTACHED"; exit 9; }
mkdir -p "$OUT"
LOG="$OUT/bench_$(date +%Y%m%d_%H%M%S).log"
LATEST="$OUT/bench.latest.log"

echo "== nvme bench start $(date) ==" | tee "$LOG"
uname -r | tee -a "$LOG"
findmnt /mnt/nvme | tee -a "$LOG"
df -h /mnt/nvme | tee -a "$LOG"
lsblk -o NAME,ROTA,SIZE,MODEL,PHY-SEC,TRAN 2>/dev/null | tee -a "$LOG"

gcc -O2 -pthread -o "$OUT/nvmebench" "$OUT/bench.c" 2>>"$LOG" || { echo "GCC-FAIL" | tee -a "$LOG"; exit 8; }
cd "$OUT"

echo "== S1 trunk seq buffered 20GiB ==" | tee -a "$LOG"
./nvmebench seq 0 21474836480 | tee -a "$LOG"

echo "== S2 trunk seq O_DIRECT 16GiB ==" | tee -a "$LOG"
./nvmebench seq 1 17179869184 | tee -a "$LOG"

echo "== S3 expert rndslot O_DIRECT 2048 slots(17.5MB) 16thr - 35.9GB ==" | tee -a "$LOG"
./nvmebench rndslot 1 2048 16 | tee -a "$LOG"

echo "== S4 expert rnd4k O_DIRECT 1,048,576 reads 16thr ==" | tee -a "$LOG"
./nvmebench rnd4k 1 1048576 16 | tee -a "$LOG"

echo "== S5 MIX seq O_DIRECT 12GiB + rndslot 1536 slots 16thr ==" | tee -a "$LOG"
./nvmebench mix 12884901888 1536 | tee -a "$LOG"

echo "== done $(date) elapsed $(( $(date +%s) - T0 ))s ==" | tee -a "$LOG"
rm -f "$LATEST"; ln -s "$(basename "$LOG")" "$LATEST"
echo "WROTE: $LOG" | tee -a "$LATEST"
exit 0