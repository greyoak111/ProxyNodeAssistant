[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$OutputPath,
    [string]$Root = (Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)),
    [string]$Version = "0.9.5"
)

$ErrorActionPreference = "Stop"
$Root = [IO.Path]::GetFullPath($Root)
$OutputPath = [IO.Path]::GetFullPath($OutputPath)
$auditRoot = Join-Path $Root ("release-privacy-check-" + [Guid]::NewGuid().ToString("N"))
$rootPrefix = $Root.TrimEnd('\') + '\'
$auditResolved = [IO.Path]::GetFullPath($auditRoot)
if (-not $auditResolved.StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Unsafe release audit path."
}

Add-Type -AssemblyName System.IO.Compression.FileSystem
New-Item -ItemType Directory -Force -Path $auditRoot | Out-Null
try {
    $portable = Join-Path $auditRoot "portable"
    $source = Join-Path $auditRoot "source"
    $apk = Join-Path $auditRoot "apk"
    $toolkit = Join-Path $auditRoot "toolkit"
    # Resolve release archives by ASCII-stable names/patterns.  Windows PowerShell
    # can decode a UTF-8 script's Chinese filename literal using the active code
    # page, which previously produced an invalid path and hid the real audit.
    $portableArchive = Get-ChildItem -LiteralPath $OutputPath -File -Filter "TextNodeAssistant-v$Version-*.zip" |
        Where-Object { $_.Name -notlike "*source*" } | Select-Object -First 1
    $sourceArchive = Get-Item -LiteralPath (Join-Path $OutputPath "TextNodeAssistant-v$Version-source.zip")
    $apkArchive = Get-Item -LiteralPath (Join-Path $OutputPath "TextNodeAssistant-v$Version-android-universal.apk")
    if (-not $portableArchive) { throw "Portable release archive was not found." }
    [IO.Compression.ZipFile]::ExtractToDirectory($portableArchive.FullName, $portable)
    [IO.Compression.ZipFile]::ExtractToDirectory($sourceArchive.FullName, $source)
    [IO.Compression.ZipFile]::ExtractToDirectory($apkArchive.FullName, $apk)
    New-Item -ItemType Directory -Force -Path $toolkit | Out-Null
    & tar.exe -xzf (Join-Path $OutputPath "text-node-assistant-toolkit-v$Version.tar.gz") -C $toolkit
    if ($LASTEXITCODE -ne 0) { throw "Toolkit extraction failed." }

    & (Join-Path $Root "scripts\test-release-privacy.ps1") -Path @($OutputPath, $auditRoot) -RequireForbiddenSet
    if (-not $?) { throw "Extracted release privacy scan failed." }

    $secretMaterials = @(Get-ChildItem -LiteralPath $source -Recurse -File | Where-Object {
        $_.Name -match '\.(?:jks|keystore)$' -or
        $_.Name -eq 'local.properties' -or
        $_.Name -match 'password\.dpapi$' -or
        $_.Name -match '^(?:id_ed25519|id_rsa)$'
    })
    if ($secretMaterials.Count -gt 0) {
        throw "Source archive contains $($secretMaterials.Count) forbidden signing/private material files."
    }

    $sbom = Get-Content -LiteralPath (Join-Path $OutputPath "TextNodeAssistant-v$Version-sbom.spdx.json") -Raw | ConvertFrom-Json
    if ($sbom.spdxVersion -ne 'SPDX-2.3' -or $sbom.packages.Count -lt 2) { throw "SBOM validation failed." }
    Write-Output "SBOM_PARSE_OK packages=$($sbom.packages.Count)"

    # The release manifest is UTF-8 because it contains localized filenames;
    # read it explicitly so Windows PowerShell's legacy code page cannot
    # corrupt paths before hashing them.
    $sumLines = @([IO.File]::ReadAllLines((Join-Path $OutputPath "SHA256SUMS-v$Version.txt"), [Text.Encoding]::UTF8))
    foreach ($line in $sumLines) {
        $hashMatch = [regex]::Match($line, '^([0-9a-f]{64})  (.+)$')
        if (-not $hashMatch.Success) { throw "Malformed SHA-256 line." }
        $relativeName = $hashMatch.Groups[2].Value
        $hashItem = Get-FileHash -LiteralPath (Join-Path $OutputPath $relativeName) -Algorithm SHA256
        if (-not $hashItem) { throw "Release hash target was not found: $relativeName" }
        $actual = $hashItem.Hash.ToLowerInvariant()
        if ($actual -ne $hashMatch.Groups[1].Value) { throw "Release SHA-256 mismatch." }
    }
    Write-Output "RELEASE_HASHES_OK count=$($sumLines.Count)"
    Write-Output "RELEASE_ARTIFACT_AUDIT_OK"
} finally {
    if ((Test-Path -LiteralPath $auditResolved) -and $auditResolved.StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        Remove-Item -LiteralPath $auditResolved -Recurse -Force
    }
}
