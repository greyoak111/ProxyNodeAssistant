$ErrorActionPreference = "Stop"

function Required([string]$p) {
    do { $v=(Read-Host $p).Trim() } while (-not $v)
    return $v
}

Write-Host "Fallback tool: create one VLESS+REALITY TEST inbound through 3x-ui API."
Write-Host "No node IP/domain/token defaults are stored in this package."
Write-Host

$base = Required 'Panel base URL through SSH tunnel (example: http://127.0.0.1:12345/randomPath)'
$base = $base.TrimEnd('/')
$cred = [pscredential]::new("token",(Read-Host "Paste 3x-ui API Token for this run" -AsSecureString))
$token = $cred.GetNetworkCredential().Password
$h = @{ Authorization = "Bearer $token" }

$ip = Required "VPS public IP or hostname"
$domain = Required "REALITY SNI / cover domain"
$portText = Read-Host "Test port [24443]"
$port = if ($portText) { [int]$portText } else { 24443 }

$list = Invoke-RestMethod -Method Get -Uri "$base/panel/api/inbounds/list" -Headers $h
if (-not $list.success) { throw "Cannot list inbounds: $($list.msg)" }
$collision = @($list.obj) | Where-Object { [int]$_.port -eq $port }
if ($collision.Count -gt 0) { throw "Port $port already exists; refusing to overwrite." }

$uuidResp = Invoke-RestMethod -Method Get -Uri "$base/panel/api/server/getNewUUID" -Headers $h
$keyResp = Invoke-RestMethod -Method Get -Uri "$base/panel/api/server/getNewX25519Cert" -Headers $h
if (-not $uuidResp.success -or -not $keyResp.success) { throw "Credential generation failed." }

$uuid = [string]$uuidResp.obj
$privateKey = [string]$keyResp.obj.privateKey
$publicKey = [string]$keyResp.obj.publicKey
if (-not $publicKey) { $publicKey = [string]$keyResp.obj.password }

$rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
$buf = New-Object byte[] 8
$rng.GetBytes($buf)
$shortId = -join ($buf | ForEach-Object { $_.ToString("x2") })
$subId = [guid]::NewGuid().ToString("N")
$email = "self-" + (Get-Date -Format "yyyyMMddHHmmss")

$payload = @{
    enable = $true
    remark = "reality-test-$port"
    listen = ""
    port = $port
    protocol = "vless"
    expiryTime = 0
    total = 0
    settings = @{
        clients = @(@{
            id=$uuid; email=$email; flow="xtls-rprx-vision"; limitIp=0; totalGB=0
            expiryTime=0; enable=$true; tgId=0; subId=$subId; comment="proxy-runbook-v0.6"
        })
        decryption="none"; encryption="none"; fallbacks=@()
    }
    streamSettings = @{
        network="tcp"; security="reality"
        tcpSettings=@{acceptProxyProtocol=$false;header=@{type="none"}}
        realitySettings=@{
            show=$false;xver=0;target="127.0.0.1:8443";serverNames=@($domain)
            privateKey=$privateKey;minClientVer="";maxClientVer="";maxTimediff=0;shortIds=@($shortId)
            settings=@{publicKey=$publicKey;fingerprint="chrome";serverName="";spiderX="/"}
        }
    }
    sniffing=@{enabled=$true;destOverride=@("http","tls");metadataOnly=$false;routeOnly=$false}
}

$result = Invoke-RestMethod -Method Post -Uri "$base/panel/api/inbounds/add" -Headers $h `
    -ContentType "application/json" -Body ($payload | ConvertTo-Json -Depth 20)
if (-not $result.success) { throw "Create inbound failed: $($result.msg)" }

$pbk=[Uri]::EscapeDataString($publicKey)
$sni=[Uri]::EscapeDataString($domain)
$sid=[Uri]::EscapeDataString($shortId)
$link="vless://$uuid@$ip`:$port?type=tcp&security=reality&pbk=$pbk&fp=chrome&sni=$sni&sid=$sid&spx=%2F&flow=xtls-rprx-vision#reality-test"

Write-Host
Write-Host "================ REAL GENERATED REALITY KEYS ============" -ForegroundColor Magenta
Write-Host "UUID=$uuid"
Write-Host "REALITY_PRIVATE_KEY=$privateKey"
Write-Host "REALITY_PUBLIC_KEY=$publicKey"
Write-Host "SHORT_ID=$shortId"
Write-Host "SUB_ID=$subId"
Write-Host "========================================================="
Write-Host "TEST_LINK=$link" -ForegroundColor Cyan
Write-Host
Write-Host "PrivateKey is shown because this is the explicit handoff screen. Never place it in the client." -ForegroundColor Yellow

$token=$null; $cred=$null
