#!/bin/bash
set -eu
if ! mountpoint -q /mnt/nvme 2>/dev/null; then
  for i in /mnt/wsl/PHYSICALDRIVE2p7; do
    [ -d "$i" ] && { mkdir -p /mnt/nvme; mount --bind "$i" /mnt/nvme; break; }
  done
fi
cd /mnt/f/kimi-k3-in-c
make -j8 2>&1 | tail -6
ls -l --time-style=+%H:%M:%S bin/k3
echo "--- strings check:"
strings bin/k3 | grep -c K3_L2_NATIVE
echo "--- objdump: L2 hit submit must carry group 1 (mov \$0x1 into the group slot):"
objdump -d bin/k3 --no-show-raw-insn | awk '/<k3_l2_load_direct>:/,/^$/' | grep -E 'mov.*0x1,|call.*k3_io_submit' | head -6
echo "BUILD_OK=$(date +%T)"