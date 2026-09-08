param(
    [Parameter(Mandatory = $true)]
    [string]$CmdFile
)

$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$ToolsRoot = Join-Path $Root ".build-tools"

function Test-GoPair([string]$GoExe, [string]$GofmtExe) {
    if (-not (Test-Path -LiteralPath $GoExe -PathType Leaf) -or -not (Test-Path -LiteralPath $GofmtExe -PathType Leaf)) {
        return $false
    }
    try {
        $versionText = (& $GoExe version 2>$null) -join " "
        if ($LASTEXITCODE -ne 0 -or $versionText -notmatch '^go version go(\d+)\.(\d+)') {
            return $false
        }
        $major = [int]$matches[1]
        $minor = [int]$matches[2]
        return $major -gt 1 -or ($major -eq 1 -and $minor -ge 23)
    } catch {
        return $false
    }
}

$goCommand = Get-Command go.exe -ErrorAction SilentlyContinue
$gofmtCommand = Get-Command gofmt.exe -ErrorAction SilentlyContinue
if ($goCommand -and $gofmtCommand -and (Test-GoPair $goCommand.Source $gofmtCommand.Source)) {
    $goExe = $goCommand.Source
    $gofmtExe = $gofmtCommand.Source
} else {
    $nativeArchitecture = if ($env:PROCESSOR_ARCHITEW6432) { $env:PROCESSOR_ARCHITEW6432 } else { $env:PROCESSOR_ARCHITECTURE }
    $goArchitecture = switch ($nativeArchitecture.ToUpperInvariant()) {
        "AMD64" { "amd64" }
        "ARM64" { "arm64" }
        "X86" { "386" }
        default { throw "Unsupported Windows build-host architecture: $nativeArchitecture" }
    }

    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Write-Host "Go was not found in PATH. Resolving the current stable portable archive from go.dev..."
    $releases = Invoke-RestMethod -UseBasicParsing -Uri "https://go.dev/dl/?mode=json"
    $release = $releases | Where-Object { $_.stable } | Select-Object -First 1
    if (-not $release) { throw "go.dev did not return a stable Go release" }
    $archive = $release.files | Where-Object {
        $_.os -eq "windows" -and $_.arch -eq $goArchitecture -and $_.kind -eq "archive" -and $_.filename -like "*.zip"
    } | Select-Object -First 1
    if (-not $archive -or $archive.sha256 -notmatch '^[0-9a-fA-F]{64}$') {
        throw "go.dev did not return a verifiable Windows $goArchitecture archive"
    }

    $downloadDir = Join-Path $ToolsRoot "downloads"
    $installDir = Join-Path $ToolsRoot ("{0}-windows-{1}" -f $release.version, $goArchitecture)
    $zipPath = Join-Path $downloadDir $archive.filename
    $goExe = Join-Path $installDir "go\bin\go.exe"
    $gofmtExe = Join-Path $installDir "go\bin\gofmt.exe"
    New-Item -ItemType Directory -Force -Path $downloadDir, $installDir | Out-Null

    if (-not (Test-GoPair $goExe $gofmtExe)) {
        $needDownload = $true
        if (Test-Path -LiteralPath $zipPath -PathType Leaf) {
            $needDownload = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash -ne $archive.sha256.ToUpperInvariant()
        }
        if ($needDownload) {
            Write-Host "Downloading $($archive.filename) from the official Go distribution site..."
            Invoke-WebRequest -UseBasicParsing -Uri ("https://go.dev/dl/" + $archive.filename) -OutFile $zipPath
        }
        $actualHash = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash
        if ($actualHash -ne $archive.sha256.ToUpperInvariant()) {
            throw "Portable Go SHA-256 verification failed: expected $($archive.sha256), got $actualHash"
        }
        Write-Host "Extracting verified portable Go into .build-tools..."
        Expand-Archive -LiteralPath $zipPath -DestinationPath $installDir -Force
        if (-not (Test-GoPair $goExe $gofmtExe)) {
            throw "Portable Go extraction completed but go.exe/gofmt.exe did not pass launch verification"
        }
    }
}

$cmdParent = Split-Path -Parent ([IO.Path]::GetFullPath($CmdFile))
if ($cmdParent) { New-Item -ItemType Directory -Force -Path $cmdParent | Out-Null }
$cmd = @(
    "set `"PNA_GO_EXE=$goExe`"",
    "set `"PNA_GOFMT_EXE=$gofmtExe`""
) -join "`r`n"
[IO.File]::WriteAllText($CmdFile, ($cmd + "`r`n"), [Text.Encoding]::ASCII)
Write-Host (& $goExe version)
