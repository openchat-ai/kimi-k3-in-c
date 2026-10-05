@echo off
REM bisect across the four distinct src/include states between 008449c and e4e206a.
REM Mounts the NVMe partition first: a schtasks WSL session does not inherit an attached
REM disk, which is what killed the first v58 run (AGENTS.md warns about exactly this).
wsl.exe --mount \\.\PHYSICALDRIVE2 --partition 7
wsl.exe -d k3 -u root -e bash -c "mkdir -p /mnt/nvme; mountpoint -q /mnt/nvme || mount --bind /mnt/wsl/PHYSICALDRIVE2p7 /mnt/nvme"
wsl.exe -d k3 -u root -e bash -c "test -r /mnt/nvme/experts.l2 || { echo 'FATAL: experts.l2 unreadable, refusing to run'; exit 1; }; test -d /mnt/nvme/embed || { echo 'FATAL: embed missing'; exit 1; }; df -h /mnt/nvme | tail -1; /root/ab59.sh > /mnt/f/kimi-k3-in-c/reports/gateab_ab/ab59_run.log 2>&1"