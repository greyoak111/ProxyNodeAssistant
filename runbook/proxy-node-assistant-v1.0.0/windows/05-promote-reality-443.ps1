$ErrorActionPreference = "Stop"

function Ensure-Property {
    param($Object, [string]$Name, $Value)
    if ($Object.PSObject.Properties.Name -contains $Name) { $Object.$Name = $Value }
    else { $Object | Add-Member -NotePropertyName $Name -NotePropertyValue $Value }
}

$base = (Read-Host 'Panel base URL through SSH tunnel').TrimEnd('/')
$idRaw = Read-Host 'Production 443 inbound ID [default 1]'
$id = if ([string]::IsNullOrWhiteSpace($idRaw)) { 1 } else { [int]$idRaw }
$cover = Read-Host 'Cover domain'

$newUuid = Read-Host 'Paste the SAME NEW UUID already proven on 24443'
$newPrivateKey = Read-Host 'Paste the SAME NEW PrivateKey'
$newPublicKey = Read-Host 'Paste the SAME NEW Password/PublicKey'
$newSid = Read-Host 'Paste the SAME NEW shortId'
$newSubId = Read-Host 'Production subId: paste desired value, or Enter to KEEP current'

$cred = [pscredential]::new("token",(Read-Host "Paste 3x-ui API Token" -AsSecureString))
$token = $cred.GetNetworkCredential().Password
$h = @{ Authorization = "Bearer $token" }

$r = Invoke-RestMethod -Method Get -Uri "$base/panel/api/inbounds/get/$id" -Headers $h
if (-not $r.success) { throw "GET failed: $($r.msg)" }
$p = $r.obj | ConvertTo-Json -Depth 100 | ConvertFrom-Json
if ($p.settings -is [string]) { $p.settings = $p.settings | ConvertFrom-Json }
if ($p.streamSettings -is [string]) { $p.streamSettings = $p.streamSettings | ConvertFrom-Json }
if ($p.sniffing -is [string]) { $p.sniffing = $p.sniffing | ConvertFrom-Json }

if ($p.port -ne 443) { throw "Refusing: inbound $id is not port 443." }
if ($p.protocol -ne "vless" -or $p.streamSettings.security -ne "reality") { throw "Refusing: production inbound is not VLESS REALITY." }
if (@($p.settings.clients).Count -ne 1) { throw "Beginner-safe script requires exactly one client." }

$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$backup = Join-Path $env:USERPROFILE "Desktop\reality-443-before-promote-$stamp.json"
$p | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $backup -Encoding UTF8
Write-Host "Full secret-bearing backup saved to $backup"

$p.settings.clients[0].id = $newUuid
if (-not [string]::IsNullOrWhiteSpace($newSubId)) {
    Ensure-Property $p.settings.clients[0] "subId" $newSubId
}

$rs = $p.streamSettings.realitySettings
Ensure-Property $rs "target" "127.0.0.1:8443"
if ($rs.PSObject.Properties.Name -contains "dest") { $rs.dest = "127.0.0.1:8443" }
$rs.serverNames = @($cover)
$rs.privateKey = $newPrivateKey
$rs.shortIds = @($newSid)
if ($null -eq $rs.settings) { Ensure-Property $rs "settings" ([pscustomobject]@{}) }
Ensure-Property $rs.settings "publicKey" $newPublicKey
Ensure-Property $rs.settings "serverName" $cover
Ensure-Property $rs.settings "fingerprint" "chrome"

$payload = [ordered]@{
    enable = $p.enable
    remark = $p.remark
    listen = $p.listen
    port = 443
    protocol = $p.protocol
    expiryTime = $p.expiryTime
    total = $p.total
    settings = $p.settings
    streamSettings = $p.streamSettings
    sniffing = $p.sniffing
}
foreach ($name in @("shareAddrStrategy","shareAddr")) {
    if ($p.PSObject.Properties.Name -contains $name) { $payload[$name] = $p.$name }
}

Write-Host "`n== NO-SECRET SUMMARY =="
[pscustomobject]@{
    Id=$id; Port=443; Target=$rs.target; SNI=$rs.serverNames[0];
    UUIDLength=$newUuid.Length; PrivateKeyLength=$newPrivateKey.Length;
    PublicKeyLength=$newPublicKey.Length; ShortIdLength=$newSid.Length
} | Format-List

$confirm = Read-Host 'This changes PRODUCTION 443. Type PROMOTE-443 only after 24443 passed proxy + fallback tests'
if ($confirm -ne "PROMOTE-443") { throw "Cancelled." }

$body = $payload | ConvertTo-Json -Depth 100
$u = Invoke-RestMethod -Method Post -Uri "$base/panel/api/inbounds/update/$id" -Headers $h -ContentType "application/json" -Body $body
if (-not $u.success) { throw "Update failed: $($u.msg)" }

Write-Host "PRODUCTION_443_UPDATED"
Write-Host "Immediately switch a client to the already-proven credentials with port changed 24443 -> 443 and test."
$token = $null
$cred = $null
