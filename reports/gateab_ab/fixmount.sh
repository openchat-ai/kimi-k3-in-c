#!/bin/bash
set -u
umount /mnt/nvme 2>/dev/null && echo "[fix] dropped tmpfs bind"
mkdir -p /mnt/nvme
mount /dev/sde7 /mnt/nvme 2>/dev/null && echo "[fix] mounted /dev/sde7 ext4" || echo "[fix] mount /dev/sde7 failed"
echo "[fix] state:"; findmnt -o TARGET,SOURCE,FSTYPE /mnt/nvme | tail -1
echo "[fix] content:"; ls /mnt/nvme | head -8
df -h /mnt/nvme | tail -1