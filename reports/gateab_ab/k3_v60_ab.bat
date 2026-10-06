@echo off
REM v60: does the device punish 17.5 MB scattered reads relative to 4M blocks? This is the one
REM measurement that decides whether further engineering has any magnitude left. Mounts the
REM partition first -- a schtasks WSL session does not inherit an attached disk.
wsl.exe --mount \\.\PHYSICALDRIVE2 --partition 7
wsl.exe -d k3 -u root -e bash -c "mkdir -p /mnt/nvme; mountpoint -q /mnt/nvme || mount --bind /mnt/wsl/PHYSICALDRIVE2p7 /mnt/nvme"
wsl.exe -d k3 -u root -e bash -c "test -r /mnt/nvme/experts.l2 || { echo 'FATAL: experts.l2 unreadable, refusing to run'; exit 1; }; df -h /mnt/nvme | tail -1; /root/ab60.sh > /mnt/f/kimi-k3-in-c/reports/gateab_ab/ab60_run.log 2>&1"