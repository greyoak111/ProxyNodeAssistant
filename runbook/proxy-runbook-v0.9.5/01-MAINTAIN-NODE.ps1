$ErrorActionPreference = "Stop"
function Req($p) { do { $v=(Read-Host $p).Trim() } while (-not $v); return $v }
function Safe($v) { return (($v -replace '[^A-Za-z0-9._-]', '_').Trim('_')) }

$hostName = Req "VPS IP or hostname"
$userName = Req "SSH user"
$p = Read-Host "SSH port [22]"
$port = if ($p) {[int]$p} else {22}

$key = Join-Path $HOME ".ssh\proxy-runbook\$(Safe $hostName)-$(Safe $userName)\id_ed25519"
$args = @()
if (Test-Path $key) { $args += @("-i",$key) }
$args += @("-tt","-p",$port,"$userName@$hostName")

$remote = if ($userName -eq "root") { "proxy-node" } else { "sudo proxy-node" }
& ssh @args $remote
