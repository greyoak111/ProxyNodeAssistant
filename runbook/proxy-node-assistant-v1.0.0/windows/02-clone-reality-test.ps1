$ErrorActionPreference = "Stop"

function Ensure-Property {
    param($Object, [string]$Name, $Value)
    if ($null -eq $Object) { throw "Cannot add property $Name to null object." }
    if ($Object.PSObject.Properties.Name -contains $Name) {
        $Object.$Name = $Value
    } else {
        $Object | Add-Member -NotePropertyName $Name -NotePropertyValue $Value
    }
}

$base = (Read-Host 'Panel base URL through SSH tunnel').TrimEnd('/')
$sourceIdRaw = Read-Host 'Source WORKING Reality inbound ID [default 1]'
$sourceId = if ([string]::IsNullOrWhiteSpace($sourceIdRaw)) { 1 } else { [int]$sourceIdRaw }
$portRaw = Read-Host 'Temporary test port [default 24443]'
$testPort = if ([string]::IsNullOrWhiteSpace($portRaw)) { 24443 } else { [int]$portRaw }
$cover = Read-Host 'Cover domain, e.g. cover.example.com'

$newUuid = Read-Host 'Paste NEW UUID'
$newPrivateKey = Read-Host 'Paste NEW Reality PrivateKey (server only)'
$newPublicKey = Read-Host 'Paste NEW Reality Password/PublicKey (client value)'
$newSid = Read-Host 'Paste NEW shortId (16 hex chars recommended)'
$newSubIdInput = Read-Host 'Paste new subId, or press Enter to generate one'
$newSubId = if ([string]::IsNullOrWhiteSpace($newSubIdInput)) { [guid]::NewGuid().ToString("N") } else { $newSubIdInput }

if ($newUuid.Length -ne 36) { throw "UUID length is not 36." }
if ($newPrivateKey.Length -lt 40) { throw "PrivateKey looks too short." }
if ($newPublicKey.Length -lt 40) { throw "PublicKey/Password looks too short." }
if ($newSid -notmatch '^[0-9a-fA-F]{2,16}$' -or ($newSid.Length % 2) -ne 0) {
    throw "shortId must be even-length hex, 2..16 chars."
}
if ($newSubId.Length -lt 8) { throw "subId looks too short." }
if ($cover -notmatch '^[A-Za-z0-9.-]+\.[A-Za-z]{2,}$') { throw "Cover domain looks invalid." }

$cred = [pscredential]::new("token",(Read-Host "Paste 3x-ui API Token" -AsSecureString))
$token = $cred.GetNetworkCredential().Password
$h = @{ Authorization = "Bearer $token" }

$srcResp = Invoke-RestMethod -Method Get -Uri "$base/panel/api/inbounds/get/$sourceId" -Headers $h
if (-not $srcResp.success) { throw "Cannot fetch source inbound: $($srcResp.msg)" }

$t = $srcResp.obj | ConvertTo-Json -Depth 100 | ConvertFrom-Json
if ($t.settings -is [string]) { $t.settings = $t.settings | ConvertFrom-Json }
if ($t.streamSettings -is [string]) { $t.streamSettings = $t.streamSettings | ConvertFrom-Json }
if ($t.sniffing -is [string]) { $t.sniffing = $t.sniffing | ConvertFrom-Json }

if ($t.protocol -ne "vless") { throw "Source inbound is not VLESS." }
if ($t.streamSettings.security -ne "reality") { throw "Source inbound is not REALITY." }
if (@($t.settings.clients).Count -ne 1) {
    throw "This beginner-safe script requires exactly ONE client in the source inbound. Found $(@($t.settings.clients).Count)."
}

$t.settings.clients[0].id = $newUuid
$t.settings.clients[0].email = "credential-rotate-test"
Ensure-Property $t.settings.clients[0] "subId" $newSubId
if ($t.settings.clients[0].PSObject.Properties.Name -contains "flow") {
    $t.settings.clients[0].flow = "xtls-rprx-vision"
}

$rs = $t.streamSettings.realitySettings
if ($null -eq $rs) { throw "realitySettings missing." }

# Current Xray uses target; dest is an alias on older/current versions.
Ensure-Property $rs "target" "127.0.0.1:8443"
if ($rs.PSObject.Properties.Name -contains "dest") { $rs.dest = "127.0.0.1:8443" }
$rs.serverNames = @($cover)
$rs.privateKey = $newPrivateKey
$rs.shortIds = @($newSid)

if ($null -eq $rs.settings) {
    Ensure-Property $rs "settings" ([pscustomobject]@{})
}
Ensure-Property $rs.settings "publicKey" $newPublicKey
Ensure-Property $rs.settings "serverName" $cover
Ensure-Property $rs.settings "fingerprint" "chrome"

$payload = [ordered]@{
    enable = $false
    remark = "credential-rotate-test"
    listen = ""
    port = $testPort
    protocol = $t.protocol
    expiryTime = 0
    total = 0
    settings = $t.settings
    streamSettings = $t.streamSettings
    sniffing = $t.sniffing
}

# Preserve share-link fields if present, but never copy database identity/counters.
foreach ($name in @("shareAddrStrategy","shareAddr")) {
    if ($t.PSObject.Properties.Name -contains $name) {
        $payload[$name] = $t.$name
    }
}

Write-Host "`n== SAFE SUMMARY (no secrets) =="
[pscustomobject]@{
    SourceId = $sourceId
    Port = $payload.port
    Enable = $payload.enable
    Protocol = $payload.protocol
    Target = $payload.streamSettings.realitySettings.target
    SNI = $payload.streamSettings.realitySettings.serverNames[0]
    UUIDLength = $newUuid.Length
    PrivateKeyLength = $newPrivateKey.Length
    PublicKeyLength = $newPublicKey.Length
    ShortIdLength = $newSid.Length
    SubIdLength = $newSubId.Length
} | Format-List

$confirm = Read-Host 'Type CREATE to create this DISABLED test inbound'
if ($confirm -ne "CREATE") { throw "Cancelled." }

$body = $payload | ConvertTo-Json -Depth 100
$add = Invoke-RestMethod -Method Post -Uri "$base/panel/api/inbounds/add" -Headers $h -ContentType "application/json" -Body $body
if (-not $add.success) { throw "Create failed: $($add.msg)" }

Write-Host "`nTEST_INBOUND_CREATED"
Write-Host "ID:" $add.obj.id
Write-Host "Port:" $testPort
Write-Host "Enable: False"
Write-Host "SubId generated/used length:" $newSubId.Length
Write-Host "Next: open UFW $testPort only for your current public IP, then run 03-set-inbound-enable.ps1."

$token = $null
$cred = $null
