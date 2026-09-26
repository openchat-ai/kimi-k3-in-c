@echo off
rem launched via schtasks so it survives the caller's process tree
wsl.exe -d k3 -u root -e bash /mnt/f/kimi-k3-in-c/reports/gateab_ab/ab.sh > F:\kimi-k3-in-c\reports\gateab_ab\runner.out.log 2>&1
exit /b %ERRORLEVEL%