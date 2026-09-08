$ErrorActionPreference = 'Stop'

$repo = Split-Path -Parent $PSScriptRoot
$helper = Join-Path $PSScriptRoot 'create_deterministic_tar.py'
if (-not (Test-Path -LiteralPath $helper -PathType Leaf)) {
    throw "missing deterministic archive helper: $helper"
}

# Keep a lightweight source guard in addition to the executable round-trip
# below.  This catches accidental removal of the fixed metadata contract even
# when a developer runs the test with a different Python implementation.
$helperSource = Get-Content -LiteralPath $helper -Raw
foreach ($needle in @(
    'FIXED_MTIME = 0',
    'FIXED_UID = 0',
    'FIXED_GID = 0',
    'EXECUTABLE_MODE = 0o755',
    'gzip.GzipFile',
    'archive.addfile(info',
    'verify_archive',
    '--all-files-executable'
)) {
    if (-not $helperSource.Contains($needle)) {
        throw "deterministic archive helper lost required contract: $needle"
    }
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
    foreach ($name in @('python', 'python3')) {
        $candidate = Get-Command $name -ErrorAction SilentlyContinue
        if ($candidate) {
            return @{ Path = $candidate.Source; Prefix = @() }
        }
    }
    $launcher = Get-Command py -ErrorAction SilentlyContinue
    if ($launcher) {
        return @{ Path = $launcher.Source; Prefix = @('-3') }
    }
    throw 'Python 3 was not found; install Python or set PNA_PYTHON_EXE.'
}

$python = Resolve-PythonCommand
$pythonPath = $python.Path
$pythonPrefix = @($python.Prefix)

$temp = Join-Path ([IO.Path]::GetTempPath()) ('pna-deterministic-tar-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $temp | Out-Null
$tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
$resolvedTemp = [IO.Path]::GetFullPath($temp).TrimEnd('\') + '\'
if (-not $resolvedTemp.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase)) {
    throw "refusing to use an unexpected temporary path: $temp"
}

function Invoke-ArchiveHelper([string[]]$Arguments) {
    & $script:pythonPath @script:pythonPrefix $script:helper @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "deterministic archive helper failed (exit $LASTEXITCODE): $($Arguments -join ' ')"
    }
}

try {
    $source = Join-Path $temp 'source'
    $linuxDir = Join-Path $source 'linux'
    New-Item -ItemType Directory -Force -Path $linuxDir | Out-Null
    [IO.File]::WriteAllText(
        (Join-Path $linuxDir 'probe.sh'),
        "#!/bin/sh`necho probe`n",
        [Text.UTF8Encoding]::new($false)
    )
    [IO.File]::WriteAllText(
        (Join-Path $source 'README.md'),
        "deterministic test`n",
        [Text.UTF8Encoding]::new($false)
    )

    $archiveOne = Join-Path $temp 'toolkit-one.tar.gz'
    $archiveTwo = Join-Path $temp 'toolkit-two.tar.gz'
    $createArgs = @(
        'create', '--source', $source, '--output', $archiveOne,
        '--root-name', 'proxy-node-assistant-v1.0.0'
    )
    Invoke-ArchiveHelper $createArgs
    Invoke-ArchiveHelper @(
        'create', '--source', $source, '--output', $archiveTwo,
        '--root-name', 'proxy-node-assistant-v1.0.0'
    )
    Invoke-ArchiveHelper @(
        'verify', '--archive', $archiveOne,
        '--root-name', 'proxy-node-assistant-v1.0.0'
    )
    $hashOne = (Get-FileHash -LiteralPath $archiveOne -Algorithm SHA256).Hash
    $hashTwo = (Get-FileHash -LiteralPath $archiveTwo -Algorithm SHA256).Hash
    if ($hashOne -ne $hashTwo) {
        throw "repeated deterministic archive builds differ: $hashOne vs $hashTwo"
    }

    $binary = Join-Path $temp 'ProxyNodeAssistant-v1.0.0-cli-linux-amd64'
    [IO.File]::WriteAllBytes($binary, [byte[]](0..255))
    $binaryArchive = Join-Path $temp 'binary.tar.gz'
    Invoke-ArchiveHelper @(
        'create', '--source', $binary, '--output', $binaryArchive,
        '--root-name', 'ProxyNodeAssistant-v1.0.0-cli-linux-amd64',
        '--all-files-executable'
    )
    Invoke-ArchiveHelper @(
        'verify', '--archive', $binaryArchive,
        '--root-name', 'ProxyNodeAssistant-v1.0.0-cli-linux-amd64',
        '--all-files-executable'
    )

    Write-Host 'DETERMINISTIC_TAR_STATIC_OK'
} finally {
    if (Test-Path -LiteralPath $temp) {
        Remove-Item -LiteralPath $temp -Recurse -Force
    }
}
