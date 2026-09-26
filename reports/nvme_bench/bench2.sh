#!/bin/bash
# nvme microbench v2 - O_DIRECT tests first, then buffered (page-cache thrash) mirroring app
set -u
NC=$'\033[0m'
B=$'\033[1;36m'
BENCH_DIR=/mnt/f/kimi-k3-in-c/reports/nvme_bench
LOG=$BENCH_DIR/bench_$(date +%Y%m%d_%H%M%S).log
exec > "$LOG" 2>&1

echo "== nvme bench v2 start $(date) =="
uname -r

# bind-fallback: if the bare disk is not attached, attach it from inside WSL if /mnt/wsl stub exists
if [ ! -f /mnt/nvme/experts.l2 ]; then
    echo "WARN: /mnt/nvme/experts.l2 missing -> trying bind fallback"
    if [ -d /mnt/wsl/PHYSICALDRIVE2p7 ]; then
        mkdir -p /mnt/nvme
        mount --bind /mnt/wsl/PHYSICALDRIVE2p7 /mnt/nvme
    fi
fi
[ -f /mnt/nvme/experts.l2 ] || { echo "FATAL: /mnt/nvme/experts.l2 missing"; exit 1; }
[ -d /mnt/nvme/trunk_layers_out ] || { echo "FATAL: /mnt/nvme/trunk_layers_out missing"; exit 1; }

echo "== mounts =="
findmnt /mnt/nvme
df -h /mnt/nvme | head -2
lsblk -d -o NAME,ROTA,SIZE,MODEL,PHY-SEC,TRAN

echo "== compile =="
gcc -O2 -o /root/nvmebench "$BENCH_DIR/bench.c" -lpthread || { echo "FATAL: compile failed"; exit 1; }
cd /root

echo "== S2MT: expert seq O_DIRECT QD8 (16GiB, 8x2GiB ranges) =="
./nvmebench seqmt 1 17179869184 8
echo "== S3D: expert rndslot O_DIRECT 16thr 2048x17.5MB =="
./nvmebench rndslot 1 2048 16
echo "== S5D: MIX seq1(O_DIRECT 12GiB) + rnd16(O_DIRECT 1536) =="
./nvmebench mix 12884901888 1 1536 1
echo "== S4: expert rnd4k O_DIRECT 16thr 262144 reads =="
./nvmebench rnd4k 1 262144 16
echo "== S3B: expert rndslot BUFFERED 16thr 2048x17.5MB (page-cache thrash) =="
sync; echo 3 > /proc/sys/vm/drop_caches
free -m | head -3
./nvmebench rndslot 0 2048 16
echo "== S5B: MIX seq1(BUFFERED 12GiB) + rnd16(BUFFERED 1536) =="
sync; echo 3 > /proc/sys/vm/drop_caches
free -m | head -3
./nvmebench mix 12884901888 0 1536 0

echo "== done $(date) =="
ln -sf "$LOG" $BENCH_DIR/bench.latest.log