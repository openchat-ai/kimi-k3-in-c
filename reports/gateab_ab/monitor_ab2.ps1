$ErrorActionPreference = "SilentlyContinue"
$ab = "F:\kimi-k3-in-c\reports\gateab_ab"
$out = Join-Path $ab "summary_ab2.txt"
$deadline = (Get-Date).AddMinutes(90)
$stable = $false
do {
    Start-Sleep -Seconds 30
    $v1 = Get-ChildItem -LiteralPath $ab -Directory | Where-Object { $_.Name -match '^v1_' } | Select-Object -First 1
    if ($v1) {
        $s = Get-ChildItem -Path $v1.FullName -Filter summary.txt -Recurse | Select-Object -First 1
        if ($s -and (Get-Date) -gt $s.LastWriteTime.AddSeconds(60)) { $stable = $true }
    }
} while (-not $stable -and (Get-Date) -lt $deadline)

"ab2 summary $(Get-Date)" | Set-Content $out
$arms = Get-ChildItem -LiteralPath $ab -Directory | Where-Object { $_.Name -match '^v[01]_' } | Sort-Object Name
foreach ($d in $arms) {
    Add-Content $out ""
    Add-Content $out "==== $($d.Name)  last=$($d.LastWriteTime)"
    $s = Get-ChildItem -Path $d.FullName -Filter summary.txt -Recurse | Select-Object -First 1
    if ($s) { Get-Content $s.FullName | Add-Content $out } else { Add-Content $out "(no summary yet)" }
}
$done = if ($stable) { "AB2-DONE" } else { "AB2-TIMEOUT-OR-INCOMPLETE" }
Add-Content $out ""
Add-Content $out "STATUS=$done"