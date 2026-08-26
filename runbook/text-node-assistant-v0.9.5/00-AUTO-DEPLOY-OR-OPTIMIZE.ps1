$ErrorActionPreference = "Stop"

function Ask-Required([string]$Prompt) {
    while ($true) {
        $v = Read-Host $Prompt
        if (-not [string]::IsNullOrWhiteSpace($v)) { return $v.Trim() }
        Write-Host "This value is required." -ForegroundColor Yellow
    }
}

function Ask-Yes([string]$Prompt, [bool]$DefaultYes = $true) {
    $suffix = if ($DefaultYes) { "[Y/n]" } else { "[y/N]" }
    $v = (Read-Host "$Prompt $suffix").Trim()
    if ([string]::IsNullOrWhiteSpace($v)) { return $DefaultYes }
    return @("y","yes") -contains $v.ToLowerInvariant()
}

function Safe-Part([string]$Value) {
    return (($Value -replace '[^A-Za-z0-9._-]', '_').Trim('_'))
}

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$archive = Join-Path $here "text-node-assistant-toolkit-v0.9.5.tar.gz"

Write-Host "============================================================"
Write-Host " Proxy Runbook v0.9.5 - Detect-first Adaptive Installer"
Write-Host "============================================================"
Write-Host
Write-Host "The shared package contains NO real VPS IP/domain/account/keys."
Write-Host "This run will ask for the connection values every time."
Write-Host

$needOpenSsh = $false
foreach ($cmd in @("ssh","scp","ssh-keygen","ssh-keyscan")) {
    if (-not (Get-Command $cmd -ErrorAction SilentlyContinue)) { $needOpenSsh = $true }
}
if ($needOpenSsh) {
    if (-not (Ask-Yes "Windows OpenSSH Client is missing. Install it automatically now?" $true)) {
        throw "OpenSSH Client is required."
    }
    Write-Host "Requesting Administrator permission to install Windows OpenSSH Client..."
    $arg = '-NoLogo -NoProfile -ExecutionPolicy Bypass -Command "Add-WindowsCapability -Online -Name OpenSSH.Client~~~~0.0.1.0"'
    $proc = Start-Process powershell.exe -Verb RunAs -Wait -PassThru -ArgumentList $arg
    if ($proc.ExitCode -ne 0) { throw "Windows OpenSSH Client installation failed." }
    foreach ($cmd in @("ssh","scp","ssh-keygen","ssh-keyscan")) {
        if (-not (Get-Command $cmd -ErrorAction SilentlyContinue)) {
            throw "OpenSSH was installed but '$cmd' is still unavailable. Reopen Windows Terminal and rerun."
        }
    }
}
if (-not (Test-Path $archive)) {
    throw "Missing $archive . Keep the launcher and tar.gz in the same folder."
}

$VpsHost = Ask-Required "VPS IP or hostname"
$SshUser = Ask-Required "Initial SSH login user (for example root/ubuntu)"
$portText = Read-Host "SSH port [22]"
$SshPort = if ([string]::IsNullOrWhiteSpace($portText)) { 22 } else { [int]$portText }

Write-Host
Write-Host "[1/7] TCP reachability..."
$tnc = Test-NetConnection $VpsHost -Port $SshPort -WarningAction SilentlyContinue
if (-not $tnc.TcpTestSucceeded) { throw "Cannot reach ${VpsHost}:${SshPort}. Nothing was uploaded." }
Write-Host "SSH TCP reachable." -ForegroundColor Green

Write-Host
Write-Host "[2/7] Server SSH public-host-key fingerprints (verify against your VPS provider if available):"
$scan = & ssh-keyscan -T 8 -p $SshPort $VpsHost 2>$null
if ($scan) {
    $scan | & ssh-keygen -lf -
} else {
    Write-Host "ssh-keyscan returned nothing; the normal SSH connection will still ask for host-key confirmation." -ForegroundColor Yellow
}

$safeHost = Safe-Part $VpsHost
$safeUser = Safe-Part $SshUser
$keyDir = Join-Path $HOME ".ssh\proxy-runbook\$safeHost-$safeUser"
$keyPath = Join-Path $keyDir "id_ed25519"
$pubPath = "$keyPath.pub"
New-Item -ItemType Directory -Force -Path $keyDir | Out-Null

if (-not (Test-Path $keyPath)) {
    Write-Host
    Write-Host "[3/7] Generating a unique Ed25519 SSH client key for THIS node..."
    & ssh-keygen -q -t ed25519 -f $keyPath -N '""' -C "proxy-runbook:$VpsHost:$SshUser"
    if ($LASTEXITCODE -ne 0) { throw "ssh-keygen failed." }
} else {
    Write-Host
    Write-Host "[3/7] Reusing the node-specific SSH key already stored on this Windows PC:"
    Write-Host $keyPath
}

# User explicitly asked to see real generated keys.
Write-Host
Write-Host "================ REAL SSH PRIVATE KEY ================" -ForegroundColor Magenta
Get-Content -Raw $keyPath | Write-Host
Write-Host "================ REAL SSH PUBLIC KEY =================" -ForegroundColor Cyan
Get-Content -Raw $pubPath | Write-Host
Write-Host "======================================================" 
Write-Host "Private key file: $keyPath"
Write-Host "Do NOT post the private key publicly." -ForegroundColor Yellow

Write-Host
Write-Host "[4/7] Installing the PUBLIC key on the VPS."
Write-Host "Your existing VPS password is NOT read or saved by this script."
Write-Host "OpenSSH itself may ask for it once; password input will not echo."
$pub = (Get-Content -Raw $pubPath).Trim()
# Avoid PowerShell CRLF/encoding surprises when piping an authorized_keys line:
# transport the public key as base64 and decode it on the Linux host.
$pubB64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($pub))
$remoteKeyInstall = "umask 077; mkdir -p `"`$HOME/.ssh`"; touch `"`$HOME/.ssh/authorized_keys`"; k=`$(printf '%s' '$pubB64' | base64 -d); grep -qxF `"`$k`" `"`$HOME/.ssh/authorized_keys`" || printf '%s\n' `"`$k`" >> `"`$HOME/.ssh/authorized_keys`"; chmod 700 `"`$HOME/.ssh`"; chmod 600 `"`$HOME/.ssh/authorized_keys`""
& ssh -p $SshPort "$SshUser@$VpsHost" $remoteKeyInstall
if ($LASTEXITCODE -ne 0) { throw "Could not install SSH public key." }

& ssh -i $keyPath -p $SshPort -o BatchMode=yes "$SshUser@$VpsHost" "printf SSH_KEY_OK"
if ($LASTEXITCODE -ne 0) { throw "SSH key install did not verify. Password login was not modified." }
Write-Host
Write-Host "SSH_KEY_OK" -ForegroundColor Green

Write-Host
Write-Host "[5/7] Uploading toolkit with the verified SSH key..."
& scp -i $keyPath -P $SshPort $archive "$SshUser@${VpsHost}:/tmp/text-node-assistant-toolkit-v0.9.5.tar.gz"
if ($LASTEXITCODE -ne 0) { throw "SCP upload failed." }

$isRoot = $SshUser -eq "root"
$extract = 'mkdir -p /opt; rm -rf /opt/text-node-assistant-v0.9.5; tar -xzf /tmp/text-node-assistant-toolkit-v0.9.5.tar.gz -C /opt; bash /opt/text-node-assistant-v0.9.5/linux/00-bootstrap-toolkit.sh'
$escapedUser = $SshUser.Replace("'","")

Write-Host
Write-Host "[6/7] Installing toolkit on the VPS..."
if ($isRoot) {
    & ssh -tt -i $keyPath -p $SshPort "$SshUser@$VpsHost" "env TNA_LOGIN_USER='$escapedUser' TNA_SSH_KEY_INSTALLED=1 bash -lc '$extract'"
} else {
    Write-Host "The VPS may ask for the sudo password of '$SshUser'." -ForegroundColor Yellow
    & ssh -tt -i $keyPath -p $SshPort "$SshUser@$VpsHost" "sudo env TNA_LOGIN_USER='$escapedUser' TNA_SSH_KEY_INSTALLED=1 bash -lc '$extract'"
}
if ($LASTEXITCODE -ne 0) { throw "Remote bootstrap failed." }

if (-not (Ask-Yes "Start adaptive install/optimization now?" $true)) {
    Write-Host "Toolkit installed. Run it later with: sudo text-node"
    exit 0
}

Write-Host
Write-Host "[7/7] Starting remote adaptive wizard."
Write-Host "IMPORTANT: cover domain and Let's Encrypt email have NO defaults."
Write-Host "You must type both yourself." -ForegroundColor Yellow
Write-Host
$wizard = "env TNA_LOGIN_USER='$escapedUser' TNA_SSH_KEY_INSTALLED=1 bash /opt/text-node-assistant-current/linux/00-auto-install-or-optimize.sh"
if ($isRoot) {
    & ssh -tt -i $keyPath -p $SshPort "$SshUser@$VpsHost" $wizard
} else {
    & ssh -tt -i $keyPath -p $SshPort "$SshUser@$VpsHost" "sudo $wizard"
}
$wizardExit = $LASTEXITCODE
if ($wizardExit -ne 0) {
    Write-Host "Remote wizard failed with exit code $wizardExit." -ForegroundColor Red
    Write-Host "No credential block will be copied and no panel tunnel will be opened from this failure branch." -ForegroundColor Yellow
    & ssh -T -i $keyPath -p $SshPort "$SshUser@$VpsHost" "sudo sh -c 'cat /etc/text-node-assistant/last-run.env /etc/text-node-assistant/cover-last-run.env 2>/dev/null || true'"
    exit $wizardExit
}

Write-Host
Write-Host "============================================================"
Write-Host " Run finished."
Write-Host " Nothing generated during this run was written back into the shared ZIP/TAR."
Write-Host " Node SSH private key remains only on this Windows PC:"
Write-Host " $keyPath"
Write-Host "============================================================"
Write-Host
Write-Host "FINAL LOCAL SSH KEY HANDOFF" -ForegroundColor Magenta
Write-Host "SSH_PRIVATE_KEY_FILE=$keyPath"
Write-Host "SSH_PUBLIC_KEY_FILE=$pubPath"
Write-Host "--- PRIVATE KEY ---"
Get-Content -Raw $keyPath | Write-Host
Write-Host "--- PUBLIC KEY ---"
Get-Content -Raw $pubPath | Write-Host
Write-Host "-------------------"

