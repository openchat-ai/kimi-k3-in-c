@echo off
rem launched via schtasks so it survives the caller's process tree
wsl.exe -d k3 -u root -e bash /mnt/f/kimi-k3-in-c/reports/nvme_bench/bench2.sh > F:\kimi-k3-in-c\reports\nvme_bench\runner.out.log 2>&1
exit /b %ERRORLEVEL%