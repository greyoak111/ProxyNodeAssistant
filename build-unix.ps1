param(
    [ValidateSet("all", "linux", "darwin")]
    [string]$Target = "all",
    [ValidateSet("all", "amd64", "arm64")]
    [string]$Architecture = "all",
    [switch]$SkipHostTests
)

$ErrorActionPreference = "Stop"

# This script deliberately builds the CLI only.  The WPF host remains a
# Windows artifact, while the workflow core is portable and uses the native
# OpenSSH/clipboard/URL adapters selected at compile time.
$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$Dist = Join-Path $Root "dist"
$ArchiveHelper = Join-Path $Root "scripts\create_deterministic_tar.py"
$Version = "1.0.0"
$Go = if ($env:PNA_GO_EXE) { $env:PNA_GO_EXE } else { "go" }
$GoResolved = Get-Command $Go -ErrorAction SilentlyContinue
if (-not $GoResolved -and -not (Test-Path -LiteralPath $Go -PathType Leaf)) {
    throw "Go toolchain was not found. Set PNA_GO_EXE or put go on PATH."
}
$GoPath = if ($GoResolved) { $GoResolved.Source } else { [IO.Path]::GetFullPath($Go) }

if (-not (Test-Path -LiteralPath $ArchiveHelper -PathType Leaf)) {
    throw "Deterministic archive helper is missing: $ArchiveHelper"
}

function Resolve-PythonCommand {
    if ($env:PNA_PYTHON_EXE) {
        $configured = Get-Command $env:PNA_PYTHON_EXE -ErrorAction SilentlyContinue
        if ($configured) {
            return @{ Path = $configured.Source; Prefix = @() }
        }
        if (Test-Path -LiteralPath $env:PNA_PYTHON_EXE -PathType Leaf) {
            return @{ Path = [IO.Path]::GetFullPath($env:PNA_PYTHON_EXE); Prefix = @() }
        }
        throw "PNA_PYTHON_EXE was set but could not be resolved: $env:PNA_PYTHON_EXE"
    }
    foreach ($name in @("python", "python3")) {
        $candidate = Get-Command $name -ErrorAction SilentlyContinue
        if ($candidate) {
            return @{ Path = $candidate.Source; Prefix = @() }
        }
    }
    $launcher = Get-Command "py" -ErrorAction SilentlyContinue
    if ($launcher) {
        return @{ Path = $launcher.Source; Prefix = @("-3") }
    }
    throw "Python 3 was not found; install Python or set PNA_PYTHON_EXE."
}

$pythonInfo = Resolve-PythonCommand
$pythonPath = $pythonInfo.Path
$pythonPrefix = @($pythonInfo.Prefix)

$targets = @()
if ($Target -eq "all" -or $Target -eq "linux") {
    $targets += "linux"
}
if ($Target -eq "all" -or $Target -eq "darwin") {
    $targets += "darwin"
}
$architectures = if ($Architecture -eq "all") { @("amd64", "arm64") } else { @($Architecture) }

New-Item -ItemType Directory -Force -Path $Dist | Out-Null

$oldCGO = $env:CGO_ENABLED
$oldGOOS = $env:GOOS
$oldGOARCH = $env:GOARCH
$built = @()
try {
    Push-Location $Root
    # Ensure the optional host test always runs for the build machine.  A
    # caller may have GOOS/GOARCH exported from another cross-build; allowing
    # those values to leak into `go test` would produce a foreign test binary
    # that cannot execute on Windows.
    $env:GOOS = $null
    $env:GOARCH = $null
    $env:CGO_ENABLED = "0"
    if (-not $SkipHostTests) {
        # Host tests exercise parsers and safety invariants without trying to
        # execute a foreign binary.  Cross-target build validation follows.
        & $GoPath test ./...
        if ($LASTEXITCODE -ne 0) { throw "Host go test failed" }
    }

    foreach ($goos in $targets) {
        foreach ($goarch in $architectures) {
            $suffix = "$goos-$goarch"
            $binaryName = "ProxyNodeAssistant-v$Version-cli-$suffix"
            $binaryPath = Join-Path $Dist $binaryName
            $archivePath = "$binaryPath.tar.gz"
            $env:GOOS = $goos
            $env:GOARCH = $goarch
            Write-Host "Building $goos/$goarch CLI..."
            & $GoPath build -trimpath -ldflags "-s -w" -o $binaryPath .
            if ($LASTEXITCODE -ne 0) { throw "Go CLI build failed for $goos/$goarch" }
            if (-not (Test-Path -LiteralPath $binaryPath -PathType Leaf) -or (Get-Item -LiteralPath $binaryPath).Length -lt 1048576) {
                throw "Cross-compiled binary for $goos/$goarch is missing or unexpectedly small"
            }

            & $pythonPath @pythonPrefix $ArchiveHelper create `
                --source $binaryPath `
                --output $archivePath `
                --root-name $binaryName `
                --all-files-executable
            if ($LASTEXITCODE -ne 0) { throw "deterministic archive creation failed for $goos/$goarch" }
            & $pythonPath @pythonPrefix $ArchiveHelper verify `
                --archive $archivePath `
                --root-name $binaryName `
                --all-files-executable
            if ($LASTEXITCODE -ne 0) { throw "deterministic archive verification failed for $goos/$goarch" }
            $built += Get-Item -LiteralPath $binaryPath, $archivePath
        }
    }
} finally {
    Pop-Location
    $env:CGO_ENABLED = $oldCGO
    $env:GOOS = $oldGOOS
    $env:GOARCH = $oldGOARCH
}

$sumPath = Join-Path $Dist "SHA256SUMS-unix-v$Version.txt"
$sumLines = $built | Sort-Object Name | ForEach-Object {
    $hash = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    "$hash  $($_.Name)"
}
[IO.File]::WriteAllText($sumPath, (($sumLines -join "`n") + "`n"), [Text.UTF8Encoding]::new($false))
$built | Select-Object Name, Length
Get-Item -LiteralPath $sumPath | Select-Object Name, Length
