param(
    [string]$GuiPath,
    [string]$CliPath,
    [ValidateSet('amd64', '386', 'arm64')]
    [string]$Architecture = 'amd64'
)

$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$sourcePath = Join-Path $root 'gui\ProxyNodeAssistant.Gui.cs'
$source = Get-Content -LiteralPath $sourcePath -Encoding UTF8 -Raw

function Assert-SourceContains([string]$needle) {
    if (-not $source.Contains($needle)) {
        throw "GUI architecture guard is missing required source token: $needle"
    }
}

@(
    'GetNativeSystemInfo',
    'EmbeddedPeArchitecture',
    'ValidateEmbeddedPayloadArchitecture',
    'ValidateEmbeddedRuntimeArchitecture',
    'ImageFileMachineArm64 = 0xAA64',
    'ProxyNodeAssistant-v1.0.0-win64.exe',
    'This GUI embeds a '
) | ForEach-Object { Assert-SourceContains $_ }

function Read-PeMachine([string]$path) {
    $bytes = [IO.File]::ReadAllBytes($path)
    return Read-PeMachineFromBytes $bytes
}

function Read-PeMachineFromBytes([byte[]]$bytes) {
    if ($bytes.Length -lt 64 -or $bytes[0] -ne 0x4d -or $bytes[1] -ne 0x5a) {
        throw 'Not a DOS executable'
    }
    $offset = [BitConverter]::ToInt32($bytes, 0x3c)
    if ($offset -lt 0 -or $offset -gt ($bytes.Length - 6) -or
        $bytes[$offset] -ne 0x50 -or $bytes[$offset + 1] -ne 0x45 -or
        $bytes[$offset + 2] -ne 0 -or $bytes[$offset + 3] -ne 0) {
        throw 'PE header is malformed'
    }
    return [BitConverter]::ToUInt16($bytes, $offset + 4)
}

function Expected-Machine([string]$architecture) {
    switch ($architecture) {
        'amd64' { return 0x8664 }
        '386' { return 0x014c }
        'arm64' { return 0xAA64 }
    }
}

if ($GuiPath -and $CliPath) {
    foreach ($path in @($GuiPath, $CliPath)) {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            throw "GUI architecture test input is missing: $path"
        }
    }
    $cliMachine = Read-PeMachine $CliPath
    $expected = Expected-Machine $Architecture
    if ($cliMachine -ne $expected) {
        throw ('CLI architecture mismatch: expected 0x{0:X4}, got 0x{1:X4}: {2}' -f $expected, $cliMachine, $CliPath)
    }

    # The legacy C# compiler emits the ARM64 GUI as AnyCPU/PE32.  Loading the
    # x64 and ARM64 GUI assemblies in a 64-bit PowerShell process is enough to
    # inspect their embedded CLI resource; x86 is checked through its direct
    # CLI artifact because a 64-bit host cannot load a PE32 .NET assembly.
    $guiMachine = Read-PeMachine $GuiPath
    if ($Architecture -eq 'amd64' -and $guiMachine -ne 0x8664) {
        throw ('x64 GUI has unexpected PE machine 0x{0:X4}: {1}' -f $guiMachine, $GuiPath)
    }
    if ($Architecture -eq '386' -and $guiMachine -ne 0x014c) {
        throw ('x86 GUI has unexpected PE machine 0x{0:X4}: {1}' -f $guiMachine, $GuiPath)
    }
    if ($Architecture -eq 'arm64' -and $guiMachine -ne 0x014c) {
        throw ('ARM64 GUI must remain AnyCPU/PE32 for .NET Framework: 0x{0:X4}' -f $guiMachine)
    }

    if ($Architecture -ne '386') {
        try {
            $assembly = [Reflection.Assembly]::LoadFile([IO.Path]::GetFullPath($GuiPath))
            $stream = $assembly.GetManifestResourceStream('ProxyNodeAssistant.Cli.exe')
            if ($null -eq $stream) { throw 'embedded CLI resource is missing' }
            $memory = New-Object IO.MemoryStream
            $stream.CopyTo($memory)
            $embedded = $memory.ToArray()
            $stream.Dispose()
            $memory.Dispose()
            $embeddedMachine = Read-PeMachineFromBytes $embedded
            if ($embeddedMachine -ne $expected) {
                throw ('GUI embedded CLI machine is 0x{0:X4}; expected 0x{1:X4}' -f $embeddedMachine, $expected)
            }
        }
        catch {
            throw "Could not inspect embedded CLI resource in $GuiPath`: $($_.Exception.Message)"
        }
    }
}

Write-Host 'GUI architecture guard/static checks: PASS'
