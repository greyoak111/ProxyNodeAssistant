$ErrorActionPreference = "Stop"

$base = (Read-Host 'Panel base URL through SSH tunnel').TrimEnd('/')
$file = Read-Host 'Path to xray-before-warp-route-*.json backup'
if (-not (Test-Path -LiteralPath $file)) { throw "Backup file not found." }

$outer = Get-Content -LiteralPath $file -Raw | ConvertFrom-Json
if ($null -eq $outer.xraySetting) { throw "Backup does not contain xraySetting." }
$xrayJson = $outer.xraySetting | ConvertTo-Json -Depth 100 -Compress
$testUrl = if ([string]::IsNullOrWhiteSpace([string]$outer.outboundTestUrl)) {
    "https://www.google.com/generate_204"
} else { [string]$outer.outboundTestUrl }

$cred = [pscredential]::new("token",(Read-Host "Paste 3x-ui API Token" -AsSecureString))
$token = $cred.GetNetworkCredential().Password
$h = @{ Authorization = "Bearer $token" }

$confirm = Read-Host 'Type RESTORE-XRAY to overwrite current Xray template with this backup'
if ($confirm -ne "RESTORE-XRAY") { throw "Cancelled." }

$body = @{ xraySetting = $xrayJson; outboundTestUrl = $testUrl }
$r = Invoke-RestMethod -Method Post -Uri "$base/panel/api/xray/update" -Headers $h -ContentType "application/x-www-form-urlencoded" -Body $body
if (-not $r.success) { throw "Restore failed: $($r.msg)" }

Write-Host "XRAY_TEMPLATE_RESTORED"
Write-Host "Restart Xray if you need the restored structure active immediately."
$token = $null
$cred = $null
