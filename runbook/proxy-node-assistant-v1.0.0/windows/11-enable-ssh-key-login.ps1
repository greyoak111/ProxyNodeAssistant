$ErrorActionPreference = "Stop"
function Req($p) { do { $v=(Read-Host $p).Trim() } while (-not $v); return $v }
function Safe($v) { return (($v -replace '[^A-Za-z0-9._-]', '_').Trim('_')) }

$hostName=Req "VPS IP or hostname"
$userName=Req "SSH user"
$p=Read-Host "SSH port [22]"
$port=if($p){[int]$p}else{22}

$keyDir=Join-Path $HOME ".ssh\proxy-runbook\$(Safe $hostName)-$(Safe $userName)"
$key=Join-Path $keyDir "id_ed25519"
$pub="$key.pub"
New-Item -ItemType Directory -Force $keyDir | Out-Null

if(-not (Test-Path $key)){
    & ssh-keygen -q -t ed25519 -f $key -N '""' -C "proxy-runbook:$hostName:$userName"
    if($LASTEXITCODE -ne 0){throw "ssh-keygen failed"}
}

Write-Host "================ REAL SSH PRIVATE KEY ================" -ForegroundColor Magenta
Get-Content -Raw $key | Write-Host
Write-Host "================ REAL SSH PUBLIC KEY =================" -ForegroundColor Cyan
Get-Content -Raw $pub | Write-Host
Write-Host "======================================================"

$pubText=(Get-Content -Raw $pub).Trim()
$pubB64=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($pubText))
$remote="umask 077; mkdir -p `"`$HOME/.ssh`"; touch `"`$HOME/.ssh/authorized_keys`"; k=`$(printf '%s' '$pubB64' | base64 -d); grep -qxF `"`$k`" `"`$HOME/.ssh/authorized_keys`" || printf '%s\n' `"`$k`" >> `"`$HOME/.ssh/authorized_keys`"; chmod 700 `"`$HOME/.ssh`"; chmod 600 `"`$HOME/.ssh/authorized_keys`""
& ssh -p $port "$userName@$hostName" $remote
if($LASTEXITCODE -ne 0){throw "public-key install failed"}

& ssh -i $key -p $port -o BatchMode=yes "$userName@$hostName" "echo SSH_KEY_OK"
if($LASTEXITCODE -ne 0){throw "key login verification failed"}
Write-Host "SSH_KEY_OK" -ForegroundColor Green
