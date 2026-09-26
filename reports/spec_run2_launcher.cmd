@echo off
rem spec_run2_launcher.cmd: 后台启动 spec_run2.sh, 立即返回
start "" /b wsl.exe -d k3 -u root -e bash -c "bash /mnt/f/kimi-k3-in-c/reports/spec_run2.sh"