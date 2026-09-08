$ErrorActionPreference = "Stop"
function Req($p) { do { $v=(Read-Host $p).Trim() } while (-not $v); return $v }
function Safe($v) { return (($v -replace '[^A-Za-z0-9._-]', '_').Trim('_')) }

$hostName = Req "VPS IP or hostname"
$userName = Req "SSH user"
$p = Read-Host "SSH port [22]"
$sshPort = if ($p) {[int]$p} else {22}
$key = Join-Path $HOME ".ssh\proxy-runbook\$(Safe $hostName)-$(Safe $userName)\id_ed25519"
$sshBase = @()
if (Test-Path $key) { $sshBase += @("-i",$key) }
$sshBase += @("-p",$sshPort,"$userName@$hostName")

$public = (& ssh @sshBase "cat /etc/proxy-runbook/public.env 2>/dev/null || true") -join "`n"
$panelPort = [regex]::Match($public,'(?m)^PANEL_PORT=(\d+)$').Groups[1].Value
$basePath = [regex]::Match($public,'(?m)^WEB_BASE_PATH=(.*)$').Groups[1].Value.Trim()

if (-not $panelPort) {
    $panelPort = Req "Panel localhost port (runtime metadata not found)"
}
$localPort = [int]$panelPort

$clean = $basePath.Trim('/')
$url = if ($clean) { "http://127.0.0.1:$localPort/$clean/" } else { "http://127.0.0.1:$localPort/" }

Write-Host
Write-Host "Keep this window OPEN."
Write-Host "Panel URL:"
Write-Host "  $url" -ForegroundColor Cyan
Write-Host
Write-Host "Tunnel: 127.0.0.1:$localPort -> VPS 127.0.0.1:$panelPort"
Write-Host "Ctrl+C closes the tunnel."
Write-Host

$tunnelArgs = @()
if (Test-Path $key) { $tunnelArgs += @("-i",$key) }
$tunnelArgs += @("-N","-p",$sshPort,"-L","127.0.0.1:$localPort`:127.0.0.1:$panelPort","$userName@$hostName")
& ssh @tunnelArgs
