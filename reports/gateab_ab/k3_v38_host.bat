@echo off
REM v38: start the host-side sampler detached, then return. The sampler launches the k3
REM run itself and samples the physical disk for as long as it runs. Nothing here blocks.
powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "F:\kimi-k3-in-c\reports\gateab_ab\hostcount38.ps1" > "F:\kimi-k3-in-c\reports\gateab_ab\v38_sampler.log" 2>&1
