#!/bin/bash
# full inventory of mounted storage & any mxfp8 content on attached drives
set -u
echo "=== lsblk ==="
lsblk -o NAME,SIZE,FSTYPE,LABEL,MOUNTPOINT 2>/dev/null | head -40
echo
echo "=== /proc/partitions ==="
cat /proc/partitions
echo
echo "=== /mnt/nvme full listing (no head) ==="
ls -la /mnt/nvme/
echo
echo "=== /mnt/wsl mounts ==="
ls -la /mnt/wsl/ 2>/dev/null
echo
echo "=== find mxfp8 anywhere under mounted trees (maxdepth 4) ==="
find /mnt/nvme /mnt/wsl -iname '*mxfp8*' 2>/dev/null | head -40
echo
echo "=== trunk_layers_out subdirs (in case mxfp8 variant nested there) ==="
ls -la /mnt/nvme/trunk_layers_out/ 2>/dev/null | head -30
echo
echo "=== embed dir ==="
ls -la /mnt/nvme/embed/ 2>/dev/null | head -10
echo done