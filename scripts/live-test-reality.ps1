param(
    [Parameter(Mandatory = $true)][string]$HostName,
    [Parameter(Mandatory = $true)][string]$UserName,
    [Parameter(Mandatory = $true)][int]$Port,
    [Parameter(Mandatory = $true)][string]$KeyPath,
    [Parameter(Mandatory = $true)][string]$KnownHostsPath,
    [Parameter(Mandatory = $true)][string]$V2rayNArchive,
    [int]$RemotePortOverride = 0,
    [string]$RuntimeDirectory = (Join-Path $env:TEMP "TextNodeAssistant-Reality-Live-Test")
)

$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.IO.Compression.FileSystem

$ssh = "C:\Program Files\OpenSSH\ssh.exe"
if (-not (Test-Path -LiteralPath $ssh -PathType Leaf)) {
    $ssh = Join-Path $env:WINDIR "System32\OpenSSH\ssh.exe"
}
foreach ($required in @($ssh, $KeyPath, $KnownHostsPath, $V2rayNArchive)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
        throw "Required live-test file is missing: $required"
    }
}

New-Item -ItemType Directory -Force -Path $RuntimeDirectory | Out-Null
$xray = Join-Path $RuntimeDirectory "xray.exe"
if (-not (Test-Path -LiteralPath $xray -PathType Leaf)) {
    $archive = [IO.Compression.ZipFile]::OpenRead($V2rayNArchive)
    try {
        $entry = $archive.GetEntry("v2rayN-windows-64/bin/xray/xray.exe")
        if ($null -eq $entry) { throw "xray.exe is missing from the supplied v2rayN archive" }
        [IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $xray, $true)
    }
    finally {
        $archive.Dispose()
    }
}

$remoteMetadata = @'
set -a
source /root/.config/proxy-runbook/reality-shadow.env
printf '%s\n' "UUID=$UUID" "PUBLIC_IP=$PUBLIC_IP" "DOMAIN=$DOMAIN" "REALITY_PUBLIC_KEY=$REALITY_PUBLIC_KEY" "SHORT_ID=$SHORT_ID" "TEST_PORT=$TEST_PORT"
'@
$state = & $ssh -i $KeyPath -p $Port `
    -o BatchMode=yes -o IdentitiesOnly=yes `
    -o "UserKnownHostsFile=$KnownHostsPath" -o StrictHostKeyChecking=yes `
    "$UserName@$HostName" $remoteMetadata
if ($LASTEXITCODE -ne 0) { throw "Could not obtain shadow test metadata" }

$values = @{}
foreach ($line in $state) {
    $separator = $line.IndexOf("=")
    if ($separator -gt 0) {
        $values[$line.Substring(0, $separator)] = $line.Substring($separator + 1)
    }
}
foreach ($name in @("UUID", "PUBLIC_IP", "DOMAIN", "REALITY_PUBLIC_KEY", "SHORT_ID", "TEST_PORT")) {
    if ([string]::IsNullOrWhiteSpace($values[$name])) { throw "Missing shadow metadata: $name" }
}
if ($RemotePortOverride -gt 0) {
    $values.TEST_PORT = [string]$RemotePortOverride
}

$reservation = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
$reservation.Start()
$localPort = ([Net.IPEndPoint]$reservation.LocalEndpoint).Port
$reservation.Stop()

$config = @{
    log = @{ loglevel = "warning" }
    inbounds = @(@{
        listen = "127.0.0.1"
        port = $localPort
        protocol = "socks"
        settings = @{ udp = $false }
    })
    outbounds = @(@{
        protocol = "vless"
        settings = @{ vnext = @(@{
            address = $values.PUBLIC_IP
            port = [int]$values.TEST_PORT
            users = @(@{
                id = $values.UUID
                encryption = "none"
                flow = "xtls-rprx-vision"
            })
        }) }
        streamSettings = @{
            network = "tcp"
            security = "reality"
            realitySettings = @{
                serverName = $values.DOMAIN
                fingerprint = "chrome"
                publicKey = $values.REALITY_PUBLIC_KEY
                shortId = $values.SHORT_ID
                spiderX = "/"
            }
        }
    })
} | ConvertTo-Json -Depth 12 -Compress

$start = [Diagnostics.ProcessStartInfo]::new()
$start.FileName = $xray
$start.UseShellExecute = $false
$start.CreateNoWindow = $true
$start.RedirectStandardInput = $true
$start.RedirectStandardOutput = $true
$start.RedirectStandardError = $true
$null = $start.ArgumentList.Add("run")
$null = $start.ArgumentList.Add("-c")
$null = $start.ArgumentList.Add("stdin:")
$process = [Diagnostics.Process]::Start($start)
try {
    $process.StandardInput.Write($config)
    $process.StandardInput.Close()
    $ready = $false
    for ($attempt = 0; $attempt -lt 40; $attempt++) {
        Start-Sleep -Milliseconds 250
        try {
            $probe = [Net.Sockets.TcpClient]::new()
            $probe.Connect("127.0.0.1", $localPort)
            $probe.Dispose()
            $ready = $true
            break
        }
        catch { }
        if ($process.HasExited) { break }
    }
    if (-not $ready) {
        $detail = $process.StandardError.ReadToEnd()
        throw "Temporary Xray client did not listen: $detail"
    }

    $proxy = "socks5h://127.0.0.1:$localPort"
    $tests = @(
        @{ Name = "Cloudflare"; URL = "https://www.cloudflare.com/cdn-cgi/trace"; Expected = "200" },
        @{ Name = "Google"; URL = "https://www.google.com/generate_204"; Expected = "204" },
        @{ Name = "Example"; URL = "https://example.com/"; Expected = "200" }
    )
    $result = [ordered]@{
        RealityConnection = "REAL_BROWSING_OK"
        RemotePort = [int]$values.TEST_PORT
    }
    foreach ($test in $tests) {
        $code = (& curl.exe --silent --show-error --max-time 25 --proxy $proxy `
            --output NUL --write-out "%{http_code}" $test.URL).Trim()
        if ($LASTEXITCODE -ne 0 -or $code -ne $test.Expected) {
            throw "$($test.Name) HTTPS through 24443 failed: code=$code exit=$LASTEXITCODE"
        }
        $result[$test.Name] = $code
    }
    $result.Client = "temporary Xray from supplied v2rayN package"
    [pscustomobject]$result
}
finally {
    if (-not $process.HasExited) {
        $process.Kill()
        $process.WaitForExit()
    }
}
