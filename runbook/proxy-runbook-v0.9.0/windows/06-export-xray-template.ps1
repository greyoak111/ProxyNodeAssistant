$ErrorActionPreference = "Stop"

$base = (Read-Host 'Panel base URL through SSH tunnel').TrimEnd('/')
$cred = [pscredential]::new("token",(Read-Host "Paste 3x-ui API Token" -AsSecureString))
$token = $cred.GetNetworkCredential().Password
$h = @{ Authorization = "Bearer $token" }

$r = Invoke-RestMethod -Method Post -Uri "$base/panel/api/xray/" -Headers $h
if (-not $r.success) { throw "Xray config fetch failed: $($r.msg)" }
$payload = $r.obj | ConvertFrom-Json
if ($null -eq $payload.xraySetting) { throw "Response did not contain xraySetting." }

$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$out = Join-Path $env:USERPROFILE "Desktop\3xui-xray-template-$stamp.json"
$payload | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $out -Encoding UTF8
Write-Host "Saved Xray template payload:"
Write-Host $out
$token = $null
$cred = $null
