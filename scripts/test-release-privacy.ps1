[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string[]]$Path,
    [switch]$RequireForbiddenSet
)

$ErrorActionPreference = "Stop"
$encoded = $env:TNA_PRIVACY_FORBIDDEN_B64
if ([string]::IsNullOrWhiteSpace($encoded)) {
    if ($RequireForbiddenSet) { throw "TNA_PRIVACY_FORBIDDEN_B64 is required for the release privacy gate." }
    Write-Output "PRIVACY_SCAN_SKIPPED_NO_PRIVATE_SET"
    exit 0
}

$decoded = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($encoded))
$forbidden = @($decoded -split "`n" | ForEach-Object { $_.Trim("`r") } | Where-Object { $_.Length -ge 4 } | Select-Object -Unique)
if ($forbidden.Count -eq 0) { throw "The decoded forbidden set is empty." }

$files = [Collections.Generic.List[IO.FileInfo]]::new()
foreach ($inputPath in $Path) {
    $resolved = [IO.Path]::GetFullPath($inputPath)
    if (Test-Path -LiteralPath $resolved -PathType Leaf) {
        $files.Add((Get-Item -LiteralPath $resolved))
    } elseif (Test-Path -LiteralPath $resolved -PathType Container) {
        Get-ChildItem -LiteralPath $resolved -Recurse -File -Force | Where-Object {
            $_.FullName -notmatch '[\\/]\.git[\\/]' -and
            $_.FullName -notmatch '[\\/](?:\.build-tools|\.android-tools|\.gradle|build)[\\/]'
        } | ForEach-Object { $files.Add($_) }
    } else {
        throw "Privacy scan path does not exist: $resolved"
    }
}

$hits = [Collections.Generic.List[string]]::new()
foreach ($file in $files) {
    if ($file.Length -gt 268435456) { continue }
    $bytes = [IO.File]::ReadAllBytes($file.FullName)
    $ascii = [Text.Encoding]::UTF8.GetString($bytes)
    $unicode = [Text.Encoding]::Unicode.GetString($bytes)
    foreach ($secret in $forbidden) {
        if ($ascii.IndexOf($secret, [StringComparison]::OrdinalIgnoreCase) -ge 0 -or
            $unicode.IndexOf($secret, [StringComparison]::OrdinalIgnoreCase) -ge 0) {
            $hits.Add($file.FullName)
            break
        }
    }
}

if ($hits.Count -gt 0) {
    Write-Output "PRIVACY_SCAN_FAILED files=$($hits.Count)"
    $hits | Sort-Object -Unique | ForEach-Object { Write-Output ("FORBIDDEN_VALUE_FILE=" + $_) }
    exit 1
}

Write-Output "PRIVACY_SCAN_OK files=$($files.Count) forbidden_values=$($forbidden.Count)"
