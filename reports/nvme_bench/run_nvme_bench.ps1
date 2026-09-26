$ErrorActionPreference = 'Stop'
$bench = 'F:\kimi-k3-in-c\reports\nvme_bench\bench.sh'
$wslbench = '/mnt/f/kimi-k3-in-c/reports/nvme_bench/bench.sh'
$runnerLog = 'F:\kimi-k3-in-c\reports\nvme_bench\runner.out.log'

"=== runner start $(Get-Date -Format o) ===" | Tee-Object -FilePath $runnerLog

function WslRoot([string]$cmd) {
    & wsl.exe -d k3 -u root -e bash -c $cmd 2>&1
    if ($LASTEXITCODE -ne 0) { throw "wsl rc=$LASTEXITCODE: $cmd" }
    return $LASTEXITCODE
}

<# ensure /mnt/nvme attached #>
$state = (WslRoot 'test -f /mnt/nvme/experts.l2 && echo YES || echo NO') | Out-String
if ($state -notmatch 'YES') {
    "attaching PHYSICALDRIVE2 p7..." | Tee-Object -FilePath $runnerLog -Append
    & wsl.exe --mount \\.\PHYSICALDRIVE2 --partition 7 2>&1 | Tee-Object -FilePath $runnerLog -Append
    & wsl.exe -d k3 -u root -e bash -c "mkdir -p /mnt/nvme; mountpoint -q /mnt/nvme || mount --bind /mnt/wsl/PHYSICALDRIVE2p7 /mnt/nvme; test -f /mnt/nvme/experts.l2 && echo ATTACHED || echo STILL-NO" 2>&1 | Tee-Object -FilePath $runnerLog -Append
}
$state2 = (WslRoot 'test -f /mnt/nvme/experts.l2 && echo YES || echo NO') | Out-String
if ($state2 -notmatch 'YES') { throw "nvme not available" }

<# run the bench (background-safe: this whole script is the detached child) #>
"running bench at $(Get-Date -Format o)" | Tee-Object -FilePath $runnerLog -Append
& wsl.exe -d k3 -u root -e bash -c "bash $wslbench" 2>&1 | Tee-Object -FilePath $runnerLog -Append
"=== runner done rc=$LASTEXITCODE $(Get-Date -Format o) ===" | Tee-Object -FilePath $runnerLog -Append
exit $LASTEXITCODE