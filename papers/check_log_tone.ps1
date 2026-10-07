$c = [System.IO.File]::ReadAllLines("F:\kimi-k3-in-c\papers\论文-慢层只读一次原则.md")
$pat = '撤回|已删除|作废|一并记录|此前据|先前引用|此前写入|予以撤回|经四次修正|本节结论改写|不再出现在|随本节一并'
Write-Output "== 剩余日志腔："
$n = 0
for ($i = 0; $i -lt $c.Count; $i++) {
  $m = [regex]::Matches($c[$i], $pat)
  if ($m.Count) {
    $names = ($m | ForEach-Object { $_.Value }) -join " / "
    Write-Output ("  第 {0} 行: {1}" -f ($i + 1), $names)
    $n++
  }
}
if ($n -eq 0) { Write-Output "  无" }
$all = $c -join ""
Write-Output ("== 日期：{0} 处" -f ([regex]::Matches($all, '20\d\d-\d\d-\d\d')).Count)
Write-Output "== 乱码："
$b = 0
for ($i = 0; $i -lt $c.Count; $i++) {
  if ($c[$i] -match "\uFFFD") { Write-Output ("  第 {0} 行" -f ($i + 1)); $b++ }
}
if ($b -eq 0) { Write-Output "  无" }
Write-Output ("== 段落数：{0}" -f ($c | Where-Object { $_.Trim() -and -not $_.Trim().StartsWith('|') }).Count)