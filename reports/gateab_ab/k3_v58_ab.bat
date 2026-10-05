@echo off
REM ab58.sh runs inside a schtasks-spawned WSL session, which does NOT inherit the disk that
REM was attached in an interactive session. AGENTS.md says this explicitly and I still shipped
REM a batch file without it, so the first run measured an empty /mnt/nvme: the probe reported
REM "stat /mnt/nvme/experts.l2: No such file or directory" and the engine reported
REM "cannot open /mnt/nvme/embed/model-00094-of-000096.safetensors". Both arms failed for the
REM same reason and the run produced three empty ledgers.
REM
REM Attach first, then bind, then run -- all inside this one invocation, because a mount made
REM elsewhere is invisible here.
wsl.exe --mount \\.\PHYSICALDRIVE2 --partition 7
wsl.exe -d k3 -u root -e bash -c "mkdir -p /mnt/nvme; mountpoint -q /mnt/nvme || mount --bind /mnt/wsl/PHYSICALDRIVE2p7 /mnt/nvme"
wsl.exe -d k3 -u root -e bash -c "test -r /mnt/nvme/experts.l2 || { echo 'FATAL: experts.l2 unreadable, refusing to run'; exit 1; }; test -d /mnt/nvme/embed || { echo 'FATAL: embed dir missing, refusing to run'; exit 1; }; df -h /mnt/nvme | tail -1; /root/ab58.sh > /mnt/f/kimi-k3-in-c/reports/gateab_ab/ab58_run.log 2>&1"