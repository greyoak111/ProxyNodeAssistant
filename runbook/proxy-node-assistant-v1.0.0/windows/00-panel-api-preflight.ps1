$ErrorActionPreference = "Stop"

$base = Read-Host 'Panel base URL through SSH tunnel, e.g. http://127.0.0.1:<panel-port>/yourBasePath'
$base = $base.TrimEnd('/')

$cred = [pscredential]::new("token",(Read-Host "Paste 3x-ui API Token" -AsSecureString))
$token = $cred.GetNetworkCredential().Password
$h = @{ Authorization = "Bearer $token" }

Write-Host "`n== Inbounds =="
$r = Invoke-RestMethod -Method Get -Uri "$base/panel/api/inbounds/list" -Headers $h
if (-not $r.success) { throw "Inbound API failed: $($r.msg)" }
$r.obj | Select-Object id,remark,port,protocol,enable | Format-Table -AutoSize

Write-Host "`n== Xray template API =="
$x = Invoke-RestMethod -Method Post -Uri "$base/panel/api/xray/" -Headers $h
if (-not $x.success) { throw "Xray API failed: $($x.msg)" }
$obj = $x.obj | ConvertFrom-Json
Write-Host "xraySetting present:" ($null -ne $obj.xraySetting)
Write-Host "outbounds:" @($obj.xraySetting.outbounds).Count
Write-Host "routing rules:" @($obj.xraySetting.routing.rules).Count

$token = $null
$cred = $null
Write-Host "`nPANEL_API_OK"
