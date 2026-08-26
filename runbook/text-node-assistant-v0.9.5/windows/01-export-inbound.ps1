$ErrorActionPreference = "Stop"

$base = (Read-Host 'Panel base URL through SSH tunnel').TrimEnd('/')
$id = Read-Host 'Inbound ID to export (e.g. 1)'
$cred = [pscredential]::new("token",(Read-Host "Paste 3x-ui API Token" -AsSecureString))
$token = $cred.GetNetworkCredential().Password
$h = @{ Authorization = "Bearer $token" }

$r = Invoke-RestMethod -Method Get -Uri "$base/panel/api/inbounds/get/$id" -Headers $h
if (-not $r.success) { throw "GET inbound failed: $($r.msg)" }

$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$out = Join-Path $env:USERPROFILE "Desktop\3xui-inbound-$id-$stamp.json"
$r.obj | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $out -Encoding UTF8

Write-Host "Saved FULL inbound backup (contains credentials):"
Write-Host $out
Write-Host "Do not upload this file."
$token = $null
$cred = $null
