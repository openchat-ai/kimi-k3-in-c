@echo off
REM v61: paired verdict on the async burst (ca0e9b9 + 3ea020c). Five interleaved pairs, primary
REM metric kio aggregate MB/s, 10% threshold per BENCH_PROTO section 14.
REM
REM The --mount call below returns WSL_E_DISK_ALREADY_MOUNTED when the partition is already
REM attached, which is the normal case after anyone has run an interactive session. That is
REM harmless: the disk stays attached, and the next line's mountpoint test is what actually
REM decides. There is deliberately no `if errorlevel` on the --mount line, so the batch
REM continues past it -- but the errorlevel is cleared so a later check cannot inherit it.
wsl.exe --mount \\.\PHYSICALDRIVE2 --partition 7
ver >nul 2>&1
wsl.exe -d k3 -u root -e bash -c "mkdir -p /mnt/nvme; mountpoint -q /mnt/nvme || mount --bind /mnt/wsl/PHYSICALDRIVE2p7 /mnt/nvme"
wsl.exe -d k3 -u root -e bash -c "test -r /mnt/nvme/experts.l2 || { echo 'FATAL: experts.l2 unreadable, refusing to run'; exit 1; }; test -d /mnt/nvme/embed || { echo 'FATAL: embed missing'; exit 1; }; df -h /mnt/nvme | tail -1; /root/ab61.sh > /mnt/f/kimi-k3-in-c/reports/gateab_ab/ab61_run.log 2>&1"