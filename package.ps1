$ErrorActionPreference = "Stop"

Add-Type -AssemblyName System.IO.Compression.FileSystem

$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$Workspace = Split-Path -Parent (Split-Path -Parent $Root)
$Output = if ($env:PNA_PACKAGE_OUTPUT) { [IO.Path]::GetFullPath($env:PNA_PACKAGE_OUTPUT) } else { Join-Path $Workspace "outputs" }
$Version = "0.9.0"
$ToolkitVersion = "0.9.0"
$Stage = Join-Path $Root ("package-stage-" + [Guid]::NewGuid().ToString("N"))
$Portable = Join-Path $Stage "ProxyNodeAssistant-v$Version-portable"
$Source = Join-Path $Stage "ProxyNodeAssistant-v$Version-source"

New-Item -ItemType Directory -Force -Path $Output, $Portable, $Source | Out-Null
try {
    $executables = @(
        (Join-Path $Root "dist\ProxyNodeAssistant-v$Version-win64.exe"),
        (Join-Path $Root "dist\ProxyNodeAssistant-v$Version-win32.exe"),
        (Join-Path $Root "dist\ProxyNodeAssistant-v$Version-win-arm64.exe")
    )
    $preview = Join-Path $Root "dist\ProxyNodeAssistant-v$Version-gui-preview.png"
    $workflowPreview = Join-Path $Root "dist\ProxyNodeAssistant-v$Version-workflow-preview.png"
    $toolkit = Join-Path $Root "assets\proxy-runbook-toolkit-v$ToolkitVersion.tar.gz"
    $manual = Join-Path $Root "ProxyNodeAssistant-v$Version-完整使用说明书.md"
    $notes = Join-Path $Root "ProxyNodeAssistant-v$Version-更新说明.md"
    $readme = Join-Path $Root "README.md"
    $iconPng = Join-Path $Root "gui\ProxyNodeAssistant-v$Version-app-icon.png"
    $iconIco = Join-Path $Root "gui\ProxyNodeAssistant-v$Version.ico"
    foreach ($required in @($executables + @($preview, $workflowPreview, $toolkit, $manual, $notes, $readme, $iconPng, $iconIco))) {
        if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
            throw "Required release input is missing: $required"
        }
    }

    Copy-Item -LiteralPath ($executables + @($preview, $workflowPreview, $toolkit, $manual, $notes, $readme, $iconPng, $iconIco)) -Destination $Portable

    Get-ChildItem -LiteralPath $Root -File | Where-Object {
        ($_.Extension -in @(".go", ".ps1", ".bat") -or $_.Name -eq "go.mod") -or
        ($_.Extension -eq ".md" -and $_.Name -notmatch '^ProxyNodeAssistant-v0\.[0-8]')
    } | Copy-Item -Destination $Source
    $sourceGui = Join-Path $Source "gui"
    New-Item -ItemType Directory -Force -Path $sourceGui | Out-Null
    foreach ($guiFile in @(
        "app.manifest", "MainWindow.xaml", "ProxyNodeAssistant.AskPass.cs", "ProxyNodeAssistant.Gui.cs",
        "ProxyNodeAssistant-v$Version-app-icon.png", "ProxyNodeAssistant-v$Version.ico"
    )) {
        Copy-Item -LiteralPath (Join-Path $Root "gui\$guiFile") -Destination $sourceGui
    }
    Copy-Item -LiteralPath (Join-Path $Root "scripts") -Destination $Source -Recurse
    $sourceRunbook = Join-Path $Source "runbook"
    New-Item -ItemType Directory -Force -Path $sourceRunbook | Out-Null
    Copy-Item -LiteralPath (Join-Path $Root "runbook\proxy-runbook-v$ToolkitVersion") -Destination $sourceRunbook -Recurse
    $sourceAssets = Join-Path $Source "assets"
    New-Item -ItemType Directory -Force -Path $sourceAssets, (Join-Path $Source "dist") | Out-Null
    Copy-Item -LiteralPath $toolkit -Destination $sourceAssets

    $portableZip = Join-Path $Output "ProxyNodeAssistant-v$Version-便携包.zip"
    $sourceZip = Join-Path $Output "ProxyNodeAssistant-v$Version-source.zip"
    foreach ($zip in @($portableZip, $sourceZip)) {
        if (Test-Path -LiteralPath $zip) { Remove-Item -LiteralPath $zip -Force }
    }
    [IO.Compression.ZipFile]::CreateFromDirectory(
        $Portable,
        $portableZip,
        [IO.Compression.CompressionLevel]::Optimal,
        $true
    )
    [IO.Compression.ZipFile]::CreateFromDirectory(
        $Source,
        $sourceZip,
        [IO.Compression.CompressionLevel]::Optimal,
        $true
    )

    Copy-Item -LiteralPath ($executables + @($preview, $workflowPreview, $toolkit, $manual, $notes, $iconPng, $iconIco)) -Destination $Output -Force

    $releaseNames = @(
        "proxy-runbook-toolkit-v$ToolkitVersion.tar.gz",
        "ProxyNodeAssistant-v$Version-便携包.zip",
        "ProxyNodeAssistant-v$Version-更新说明.md",
        "ProxyNodeAssistant-v$Version-完整使用说明书.md",
        "ProxyNodeAssistant-v$Version-source.zip",
        "ProxyNodeAssistant-v$Version-win64.exe",
        "ProxyNodeAssistant-v$Version-win32.exe",
        "ProxyNodeAssistant-v$Version-win-arm64.exe",
        "ProxyNodeAssistant-v$Version-gui-preview.png",
        "ProxyNodeAssistant-v$Version-workflow-preview.png",
        "ProxyNodeAssistant-v$Version-app-icon.png",
        "ProxyNodeAssistant-v$Version.ico"
    )
    $hashLines = foreach ($name in $releaseNames) {
        $path = Join-Path $Output $name
        $hash = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
        "$hash  $name"
    }
    $sumPath = Join-Path $Output "SHA256SUMS-v$Version.txt"
    [IO.File]::WriteAllText($sumPath, (($hashLines -join "`n") + "`n"), [Text.UTF8Encoding]::new($false))
    $releasePaths = @($releaseNames | ForEach-Object { Join-Path $Output $_ }) + @($sumPath)
    Get-Item -LiteralPath $releasePaths | Select-Object Name, Length
} finally {
    $resolvedRoot = [IO.Path]::GetFullPath($Root).TrimEnd('\') + '\'
    $resolvedStage = [IO.Path]::GetFullPath($Stage)
    if ((Test-Path -LiteralPath $Stage) -and $resolvedStage.StartsWith($resolvedRoot, [StringComparison]::OrdinalIgnoreCase)) {
        Remove-Item -LiteralPath $Stage -Recurse -Force
    }
}
