# Host-side storage counters, sampled around a k3 run.

# Why this and not more guest-side probes. The guest has no hardware PMU: WSL2's
# hypervisor does not virtualise it (no cpu event source, no uncore_imc_*, no
# /dev/perf_event, no /sys/fs/resctrl -- see pmu_probe.sh and BENCH_PROTO section 12). The
# guest's only I/O observability is /proc/diskstats plus the engine's own ledger, and
# between them they could not explain the >=2.7x gap between the engine's 410 MB/s and the
# probe's 1100-1800 MB/s, nor the 47% run-to-run swing in that probe.

# What the host can see that the guest cannot, and why each matters:
#
#   % Idle Time          whether the physical drive was actually saturated at that moment.
#                        This is the covariate BENCH_PROTO section 11 asks for: if the
#                        47% swing tracks host-side idle time, the swing is the drive; if
#                        the drive was saturated throughout, the swing is not.
#   Avg. Disk sec/Read   real device latency, something the guest never observes at all.
#   Current Disk Queue Length  queue depth actually being offered. The guest believed it
#                        was issuing 16 concurrent reads; only the host can confirm.
#   Disk Read Bytes/sec   physical throughput, against which the guest's own byte counters
#                        can be checked for VHDX amplification.
#
# The host samples the physical disk, which is downstream of the guest's VHDX, so this
# measures the drive's true state rather than the guest's view of it. That is the point:
# it is the reference the guest cannot provide for itself.
#
# No drop_caches, no guest writes, no other disk activity. The sampler is read-only and
# lives on the Windows side, so it does not perturb the guest's filesystem at all -- which
# is itself a departure from every probe run today, each of which touched the disk it was
# measuring.

param(
  [int]$Gen = 8,
  [int]$TrunkGb = 32,
  [int]$CacheGb = 15
)

$ErrorActionPreference = "Stop"
$outDir = "F:\kimi-k3-in-c\reports\gateab_ab\v38_hostcounters"
New-Item -ItemType Directory -Force -Path $outDir | Out-Null
$stamp = Get-Date -Format "yyyyMMdd_HHmmss"
$out    = Join-Path $outDir "sample-$stamp.csv"
$meta   = Join-Path $outDir "meta-$stamp.txt"

$paths = @(
  '\PhysicalDisk(*)\% Idle Time',
  '\PhysicalDisk(*)\Avg. Disk sec/Read',
  '\PhysicalDisk(*)\Avg. Disk sec/Transfer',
  '\PhysicalDisk(*)\Current Disk Queue Length',
  '\PhysicalDisk(*)\Avg. Disk Queue Length',
  '\PhysicalDisk(*)\Disk Read Bytes/sec',
  '\PhysicalDisk(*)\Disk Read Bytes/Transfer',
  '\PhysicalDisk(*)\Avg. Disk Bytes/Read',
  '\PhysicalDisk(*)\Disk Reads/sec'
)

function Get-Sample {
  param([string]$Tag)
  $s = (Get-Counter $paths -SampleInterval 1 -MaxSamples 1 -ErrorAction SilentlyContinue).CounterSamples
  foreach ($c in $s) {
    if ($c.InstanceName -eq '_total') { continue }
    [pscustomobject]@{
      Time    = (Get-Date).ToString('HH:mm:ss')
      Tag     = $Tag
      Path    = $c.Path
      Disk    = $c.InstanceName
      Value   = [math]::Round($c.CookedValue, 4)
    }
  }
}

$all = @()
$all += Get-Sample "idle_before"

Write-Output "[v38] baseline captured, launching k3 (gen $Gen, trunk $TrunkGb / cache $CacheGb)"
$log = "F:\kimi-k3-in-c\reports\gateab_ab\v38_hostcounters\k3-$stamp.log"
$bat = "F:\kimi-k3-in-c\reports\gateab_ab\v38_hostcounters\k3-$stamp.bat"
@"
wsl.exe -d k3 -u root -e bash /mnt/f/kimi-k3-in-c/reports/gateab_ab/ab38.sh
"@ | Set-Content -Path $bat -Encoding ASCII

$proc = Start-Process -FilePath "cmd.exe" -ArgumentList "/c", "`"$bat`"" -WindowStyle Hidden -PassThru

# Sample for as long as the run takes, then a little past it.
$tick = 0
while (-not $proc.HasExited) {
  $tick++
  $all += Get-Sample "run"
  if ($tick % 60 -eq 0) { Write-Output "[v38]   still running, $tick s sampled" }
  Start-Sleep -Seconds 1
}
$all += Get-Sample "idle_after"
$all | Export-Csv -Path $out -NoTypeInformation -Encoding UTF8

$jl = if (Test-Path "\\wsl$\k3\tmp\v38.json") { Get-Content "\\wsl$\k3\tmp\v38.json" -Raw } else { "" }
@"
sample file : $out
started     : $stamp
k3 log      : $log
k3 result   : $jl
"@ | Set-Content -Path $meta -Encoding UTF8

Write-Output "[v38] sampling done, $tick seconds captured -> $out"
Write-Output "[v38] k3 result: $jl"
