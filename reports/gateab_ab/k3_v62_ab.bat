@echo off
REM v62: reproduce paper table 3 ({LRU,heat} x {8,15} GB), judged on the byte column because
REM that is what the conclusion cites and bytes are the stable observable. Mounts the partition
REM first -- a schtasks WSL session does not inherit an attached disk.
wsl.exe --mount \\.\PHYSICALDRIVE2 --partition 7
ver >nul 2>&1
wsl.exe -d k3 -u root -e bash -c "mkdir -p /mnt/nvme; mountpoint -q /mnt/nvme || mount --bind /mnt/wsl/PHYSICALDRIVE2p7 /mnt/nvme"
wsl.exe -d k3 -u root -e bash -c "test -r /mnt/nvme/experts.l2 || { echo 'FATAL: experts.l2 unreadable, refusing to run'; exit 1; }; test -d /mnt/nvme/embed || { echo 'FATAL: embed missing'; exit 1; }; df -h /mnt/nvme | tail -1; /root/ab62.sh > /mnt/f/kimi-k3-in-c/reports/gateab_ab/ab62_run.log 2>&1"