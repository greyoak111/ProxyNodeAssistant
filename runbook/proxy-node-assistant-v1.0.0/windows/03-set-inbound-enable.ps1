$ErrorActionPreference = "Stop"

$base = (Read-Host 'Panel base URL through SSH tunnel').TrimEnd('/')
$id = [int](Read-Host 'Inbound ID')
$choice = (Read-Host 'Enable? type yes or no').ToLowerInvariant()
if ($choice -notin @('yes','no')) { throw "Type yes or no." }
$enable = ($choice -eq 'yes')

$cred = [pscredential]::new("token",(Read-Host "Paste 3x-ui API Token" -AsSecureString))
$token = $cred.GetNetworkCredential().Password
$h = @{ Authorization = "Bearer $token" }

$body = @{ enable = $enable } | ConvertTo-Json
$r = Invoke-RestMethod -Method Post -Uri "$base/panel/api/inbounds/setEnable/$id" -Headers $h -ContentType "application/json" -Body $body
if (-not $r.success) { throw "setEnable failed: $($r.msg)" }

Write-Host "INBOUND_ENABLE_UPDATED id=$id enable=$enable"
$token = $null
$cred = $null
