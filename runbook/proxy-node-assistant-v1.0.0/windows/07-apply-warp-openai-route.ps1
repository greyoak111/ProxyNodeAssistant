$ErrorActionPreference = "Stop"

$base = (Read-Host 'Panel base URL through SSH tunnel').TrimEnd('/')
$warpPortRaw = Read-Host 'WARP Local Proxy port [default 40000]'
$warpPort = if ([string]::IsNullOrWhiteSpace($warpPortRaw)) { 40000 } else { [int]$warpPortRaw }

$cred = [pscredential]::new("token",(Read-Host "Paste 3x-ui API Token" -AsSecureString))
$token = $cred.GetNetworkCredential().Password
$h = @{ Authorization = "Bearer $token" }

$r = Invoke-RestMethod -Method Post -Uri "$base/panel/api/xray/" -Headers $h
if (-not $r.success) { throw "Cannot fetch Xray settings: $($r.msg)" }

$outer = $r.obj | ConvertFrom-Json
$cfg = $outer.xraySetting
if ($null -eq $cfg) { throw "xraySetting missing from response." }

$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$backup = Join-Path $env:USERPROFILE "Desktop\xray-before-warp-route-$stamp.json"
$outer | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $backup -Encoding UTF8
Write-Host "Backup saved: $backup"

if ($null -eq $cfg.outbounds) { $cfg | Add-Member -NotePropertyName outbounds -NotePropertyValue @() }
$existingOut = @($cfg.outbounds)
$cfg.outbounds = @($existingOut | Where-Object { $_.tag -ne "warp-masque" })
$warpOutbound = [pscustomobject]@{
    tag = "warp-masque"
    protocol = "socks"
    settings = [pscustomobject]@{
        address = "127.0.0.1"
        port = $warpPort
    }
}
$cfg.outbounds = @($cfg.outbounds) + $warpOutbound

if ($null -eq $cfg.routing) {
    $cfg | Add-Member -NotePropertyName routing -NotePropertyValue ([pscustomobject]@{
        domainStrategy = "AsIs"
        rules = @()
    })
}
if ($null -eq $cfg.routing.rules) { $cfg.routing.rules = @() }

# Idempotent: remove only our own named rule.
$cfg.routing.rules = @($cfg.routing.rules | Where-Object { $_.ruleTag -ne "openai-via-warp" })
$openaiRule = [pscustomobject]@{
    type = "field"
    ruleTag = "openai-via-warp"
    domain = @(
        "geosite:openai",
        "domain:chatgpt.com",
        "domain:openai.com",
        "domain:oaistatic.com",
        "domain:oaiusercontent.com"
    )
    outboundTag = "warp-masque"
}
$cfg.routing.rules = @($openaiRule) + @($cfg.routing.rules)

Write-Host "`n== OUTBOUND TEST BEFORE SAVE =="
$testBody = @{
    outbounds = (@($warpOutbound) | ConvertTo-Json -Depth 50 -Compress)
    allOutbounds = (@($cfg.outbounds) | ConvertTo-Json -Depth 50 -Compress)
    mode = "http"
}
try {
    $t = Invoke-RestMethod -Method Post -Uri "$base/panel/api/xray/testOutbounds" -Headers $h -ContentType "application/x-www-form-urlencoded" -Body $testBody
    $t | ConvertTo-Json -Depth 20
    if (-not $t.success) { throw "3x-ui outbound test failed." }
} catch {
    Write-Warning "Outbound pre-test failed: $($_.Exception.Message)"
    $force = Read-Host 'Type CONTINUE-WITHOUT-TEST to proceed anyway, anything else cancels'
    if ($force -ne "CONTINUE-WITHOUT-TEST") { throw "Cancelled because outbound was not proven." }
}

Write-Host "`n== NO-SECRET PLAN =="
Write-Host "Outbound tag: warp-masque"
Write-Host "SOCKS: 127.0.0.1:$warpPort"
Write-Host "Rule tag: openai-via-warp"
Write-Host "Rule domains: geosite:openai + explicit OpenAI/ChatGPT suffixes"
Write-Host "Existing unrelated outbounds/rules are preserved."

$confirm = Read-Host 'Type APPLY-WARP-ROUTE to save Xray template'
if ($confirm -ne "APPLY-WARP-ROUTE") { throw "Cancelled." }

$xrayJson = $cfg | ConvertTo-Json -Depth 100 -Compress
$testUrl = if ([string]::IsNullOrWhiteSpace([string]$outer.outboundTestUrl)) {
    "https://www.google.com/generate_204"
} else {
    [string]$outer.outboundTestUrl
}

$saveBody = @{
    xraySetting = $xrayJson
    outboundTestUrl = $testUrl
}
$s = Invoke-RestMethod -Method Post -Uri "$base/panel/api/xray/update" -Headers $h -ContentType "application/x-www-form-urlencoded" -Body $saveBody
if (-not $s.success) { throw "Xray template save failed: $($s.msg)" }

Write-Host "XRAY_TEMPLATE_SAVED"
Write-Host "A structural routing change normally needs Xray reload/restart to become active."

$restart = Read-Host 'Type RESTART-XRAY to restart Xray now (briefly interrupts proxy); otherwise press Enter'
if ($restart -eq "RESTART-XRAY") {
    $rr = Invoke-RestMethod -Method Post -Uri "$base/panel/api/server/restartXrayService" -Headers $h
    $rr | ConvertTo-Json -Depth 20
    Start-Sleep -Seconds 4
    Write-Host "Xray restart requested. Re-test your Reality client immediately."
}

$token = $null
$cred = $null
