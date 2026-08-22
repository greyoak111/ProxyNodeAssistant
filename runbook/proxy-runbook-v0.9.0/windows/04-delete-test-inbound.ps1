$ErrorActionPreference = "Stop"

$base = (Read-Host 'Panel base URL through SSH tunnel').TrimEnd('/')
$id = [int](Read-Host 'TEST inbound ID to delete')
$confirm = Read-Host "Type DELETE-$id to permanently delete this inbound"
if ($confirm -ne "DELETE-$id") { throw "Cancelled." }

$cred = [pscredential]::new("token",(Read-Host "Paste 3x-ui API Token" -AsSecureString))
$token = $cred.GetNetworkCredential().Password
$h = @{ Authorization = "Bearer $token" }

$r = Invoke-RestMethod -Method Post -Uri "$base/panel/api/inbounds/del/$id" -Headers $h
if (-not $r.success) { throw "Delete failed: $($r.msg)" }

Write-Host "INBOUND_DELETED id=$id"
Write-Host "For Reality credential revocation, restart Xray after deleting/rotating old users if you need immediate certainty."
$token = $null
$cred = $null
