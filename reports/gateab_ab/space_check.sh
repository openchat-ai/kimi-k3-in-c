#!/bin/bash
# Space check before v39. v39 preconditions the device by writing tens of GB, so the
# filesystem must have room, and the write must not disturb experts.l2.
set -u
echo "--- /mnt/nvme 可用空间:"
df -h /mnt/nvme | tail -1
echo
echo "--- 目录内容:"
ls -la /mnt/nvme/ | head -14
echo
echo "--- experts.l2 大小:"
ls -la /mnt/nvme/experts.l2 2>/dev/null | awk '{printf "  %.1f GB\n", $5/1e9}'
echo
echo "--- 临时目录是否在 /mnt/nvme 上（预条件写入的位置）:"
df -h /mnt/nvme/precond 2>/dev/null | tail -1 || echo "  (尚未创建)"
