param(
  [int]$Seconds = 300,
  [string]$Out = "F:\kimi-k3-in-c\reports\gateab_ab\v46_drift\host.csv"
)
# Samples the physical drive from the Windows side, once a second, for the duration of the
# guest-side drift probe. The guest has no PMU (BENCH_PROTO section 12), so this is the only
# instrument that can say what the drive was doing during a collapse.
$dir = Split-Path -Parent $Out
if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }

$paths = @(
  '\PhysicalDisk(2)\% Idle Time',
  '\PhysicalDisk(2)\Avg. Disk sec/Read',
  '\PhysicalDisk(2)\Current Disk Queue Length',
  '\PhysicalDisk(2)\Disk Read Bytes/sec',
  '\PhysicalDisk(2)\Disk Reads/sec'
)

"start,HH:MM:SS,loadavg,idle_pct,avglat_ms,qlen,read_MBps,reads_s" | Set-Content $Out
$load = (Get-Counter '\Processor(_Total)\% Processor Time' -MaxSamples 1).CounterSamples[0].CookedValue

for ($i = 0; $i -lt $Seconds; $i++) {
  $s = (Get-Counter $paths -MaxSamples 1 -ErrorAction SilentlyContinue).CounterSamples
  $m = @{}
  foreach ($c in $s) { $m[$c.Path.Split('\')[-1]] = $c.CookedValue }
  $la = (Get-Content /proc/loadavg -ErrorAction SilentlyContinue) 2>$null
  "{0},{1},{2:N1},{3:N2},{4:N3},{5:N0},{6:N2},{7:N2}" -f `
      $i,
      (Get-Date).ToString("HH:mm:ss"),
      0,
      $(if ($m.ContainsKey('% idle time')) { $m['% idle time'] } else { -1 }),
      $(if ($m.ContainsKey('avg. disk sec/read')) { $m['avg. disk sec/read'] * 1000 } else { -1 }),
      $(if ($m.ContainsKey('current disk queue length')) { $m['current disk queue length'] } else { -1 }),
      $(if ($m.ContainsKey('disk read bytes/sec')) { $m['disk read bytes/sec'] / 1MB } else { -1 }),
      $(if ($m.ContainsKey('disk reads/sec')) { $m['disk reads/sec'] } else { -1 }) |
    Add-Content $Out
  Start-Sleep -Seconds 1
}
"sampler done" | Add-Content $Out
