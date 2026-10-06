@echo off
REM v60b: fixed read counts instead of a clock in the loop, and a parser that strips the
REM punctuation dd puts around its numbers. Mounts the partition first.
wsl.exe --mount \\.\PHYSICALDRIVE2 --partition 7
wsl.exe -d k3 -u root -e bash -c "mkdir -p /mnt/nvme; mountpoint -q /mnt/nvme || mount --bind /mnt/wsl/PHYSICALDRIVE2p7 /mnt/nvme"
wsl.exe -d k3 -u root -e bash -c "test -r /mnt/nvme/experts.l2 || { echo 'FATAL: experts.l2 unreadable, refusing to run'; exit 1; }; df -h /mnt/nvme | tail -1; /root/ab60b.sh > /mnt/f/kimi-k3-in-c/reports/gateab_ab/ab60b_run.log 2>&1"