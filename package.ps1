$ErrorActionPreference = "Stop"

Add-Type -AssemblyName System.IO.Compression.FileSystem

$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$Workspace = Split-Path -Parent (Split-Path -Parent $Root)
$Output = if ($env:TNA_PACKAGE_OUTPUT) { [IO.Path]::GetFullPath($env:TNA_PACKAGE_OUTPUT) } elseif ($env:PNA_PACKAGE_OUTPUT) { [IO.Path]::GetFullPath($env:PNA_PACKAGE_OUTPUT) } else { Join-Path $Workspace "outputs" }
$Version = "0.9.5"
$ToolkitVersion = "0.9.5"
$ManualSuffix = -join ([char[]]@(0x5B8C, 0x6574, 0x4F7F, 0x7528, 0x8BF4, 0x660E, 0x4E66))
$BeginnerGuideSuffix = -join ([char[]]@(0x4ECE, 0x96F6, 0x90E8, 0x7F72, 0x6559, 0x7A0B))
$ReleaseNotesSuffix = -join ([char[]]@(0x66F4, 0x65B0, 0x8BF4, 0x660E))
$PortableSuffix = -join ([char[]]@(0x4FBF, 0x643A, 0x5305))
$Stage = Join-Path $Root ("package-stage-" + [Guid]::NewGuid().ToString("N"))
$Portable = Join-Path $Stage "TextNodeAssistant-v$Version-portable"
$Source = Join-Path $Stage "TextNodeAssistant-v$Version-source"

New-Item -ItemType Directory -Force -Path $Output, $Portable, $Source | Out-Null
try {
    $executables = @(
        (Join-Path $Root "dist\TextNodeAssistant-v$Version-win64.exe"),
        (Join-Path $Root "dist\TextNodeAssistant-v$Version-win32.exe"),
        (Join-Path $Root "dist\TextNodeAssistant-v$Version-win-arm64.exe")
    )
    $preview = Join-Path $Root "dist\TextNodeAssistant-v$Version-gui-preview.png"
    $workflowPreview = Join-Path $Root "dist\TextNodeAssistant-v$Version-workflow-preview.png"
    $toolkit = Join-Path $Root "assets\text-node-assistant-toolkit-v$ToolkitVersion.tar.gz"
    $manual = Join-Path $Root "TextNodeAssistant-v$Version-$ManualSuffix.md"
    $beginnerGuide = Join-Path $Root "TextNodeAssistant-v$Version-$BeginnerGuideSuffix.md"
    $notes = Join-Path $Root "TextNodeAssistant-v$Version-$ReleaseNotesSuffix.md"
    $readme = Join-Path $Root "README.md"
    $license = Join-Path $Root "LICENSE"
    $androidManual = Join-Path $Root "ANDROID.md"
    $androidManualName = "TextNodeAssistant-v$Version-android-manual-zh-CN.md"
    $androidApk = Join-Path $Root "android\dist\TextNodeAssistant-v$Version-android-universal.apk"
    $sbom = Join-Path $Stage "TextNodeAssistant-v$Version-sbom.spdx.json"
    $iconPng = Join-Path $Root "gui\TextNodeAssistant-v$Version-app-icon.png"
    $iconIco = Join-Path $Root "gui\TextNodeAssistant-v$Version.ico"
    foreach ($required in @($executables + @($preview, $workflowPreview, $toolkit, $manual, $beginnerGuide, $notes, $readme, $license, $androidManual, $androidApk, $iconPng, $iconIco))) {
        if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
            throw "Required release input is missing: $required"
        }
    }

    & (Join-Path $Root "scripts\generate-sbom.ps1") -OutputPath $sbom -Root $Root -Version $Version | Out-Host
    if (-not $? -or -not (Test-Path -LiteralPath $sbom -PathType Leaf)) {
        throw "SPDX SBOM generation failed."
    }

    Copy-Item -LiteralPath ($executables + @($preview, $workflowPreview, $toolkit, $manual, $beginnerGuide, $notes, $readme, $license, $iconPng, $iconIco, $sbom, $androidApk)) -Destination $Portable
    Copy-Item -LiteralPath $androidManual -Destination (Join-Path $Portable $androidManualName)

    Get-ChildItem -LiteralPath $Root -File | Where-Object {
        ($_.Extension -in @(".go", ".ps1", ".bat") -or $_.Name -in @("go.mod", "go.sum", "LICENSE")) -or
        ($_.Extension -eq ".md" -and $_.Name -notmatch '^(?:ProxyNodeAssistant|TextNodeAssistant)-v0\.[0-8]')
    } | Copy-Item -Destination $Source
    $sourceGui = Join-Path $Source "gui"
    New-Item -ItemType Directory -Force -Path $sourceGui | Out-Null
    foreach ($guiFile in @(
        "app.manifest", "MainWindow.xaml", "TextNodeAssistant.AskPass.cs", "TextNodeAssistant.Gui.cs", "TextNodeAssistant.DriveShell.cs",
        "TextNodeAssistant-v$Version-app-icon.png", "TextNodeAssistant-v$Version.ico"
    )) {
        Copy-Item -LiteralPath (Join-Path $Root "gui\$guiFile") -Destination $sourceGui
    }
    Copy-Item -LiteralPath (Join-Path $Root "scripts") -Destination $Source -Recurse
    $sourceAndroid = Join-Path $Source "android"
    $sourceAndroidApp = Join-Path $sourceAndroid "app"
    New-Item -ItemType Directory -Force -Path $sourceAndroid, $sourceAndroidApp | Out-Null
    foreach ($androidRootFile in @(
        "settings.gradle.kts", "gradle.properties", "build.gradle.kts",
        "build-android.ps1", "build-signed-release.ps1"
    )) {
        Copy-Item -LiteralPath (Join-Path $Root "android\$androidRootFile") -Destination $sourceAndroid
    }
    foreach ($androidAppFile in @("build.gradle.kts", "proguard-rules.pro")) {
        Copy-Item -LiteralPath (Join-Path $Root "android\app\$androidAppFile") -Destination $sourceAndroidApp
    }
    Copy-Item -LiteralPath (Join-Path $Root "android\app\src") -Destination $sourceAndroidApp -Recurse
    $sourceRunbook = Join-Path $Source "runbook"
    New-Item -ItemType Directory -Force -Path $sourceRunbook | Out-Null
    Copy-Item -LiteralPath (Join-Path $Root "runbook\text-node-assistant-v$ToolkitVersion") -Destination $sourceRunbook -Recurse
    $sourceAssets = Join-Path $Source "assets"
    New-Item -ItemType Directory -Force -Path $sourceAssets, (Join-Path $Source "dist") | Out-Null
    Copy-Item -LiteralPath $toolkit -Destination $sourceAssets
    Copy-Item -LiteralPath $sbom -Destination $Source

    if (-not [string]::IsNullOrWhiteSpace($env:TNA_PRIVACY_FORBIDDEN_B64)) {
        & (Join-Path $Root "scripts\test-release-privacy.ps1") -Path @($Portable, $Source) -RequireForbiddenSet | Out-Host
        if (-not $?) { throw "Release privacy gate failed before archive creation." }
    } else {
        Write-Warning "TNA_PRIVACY_FORBIDDEN_B64 is not set; private-value release gate was not run by package.ps1."
    }

    $portableZip = Join-Path $Output "TextNodeAssistant-v$Version-$PortableSuffix.zip"
    $sourceZip = Join-Path $Output "TextNodeAssistant-v$Version-source.zip"
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

    Copy-Item -LiteralPath ($executables + @($preview, $workflowPreview, $toolkit, $manual, $beginnerGuide, $notes, $iconPng, $iconIco, $androidApk, $sbom)) -Destination $Output -Force
    Copy-Item -LiteralPath $androidManual -Destination (Join-Path $Output $androidManualName) -Force

    $releaseNames = @(
        "text-node-assistant-toolkit-v$ToolkitVersion.tar.gz",
        "TextNodeAssistant-v$Version-$PortableSuffix.zip",
        "TextNodeAssistant-v$Version-$ReleaseNotesSuffix.md",
        "TextNodeAssistant-v$Version-$BeginnerGuideSuffix.md",
        "TextNodeAssistant-v$Version-$ManualSuffix.md",
        $androidManualName,
        "TextNodeAssistant-v$Version-source.zip",
        "TextNodeAssistant-v$Version-sbom.spdx.json",
        "TextNodeAssistant-v$Version-win64.exe",
        "TextNodeAssistant-v$Version-win32.exe",
        "TextNodeAssistant-v$Version-win-arm64.exe",
        "TextNodeAssistant-v$Version-gui-preview.png",
        "TextNodeAssistant-v$Version-workflow-preview.png",
        "TextNodeAssistant-v$Version-app-icon.png",
        "TextNodeAssistant-v$Version.ico"
    )
    $releaseNames += "TextNodeAssistant-v$Version-android-universal.apk"
    $hashLines = foreach ($name in $releaseNames) {
        $path = Join-Path $Output $name
        $hash = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
        "$hash  $name"
    }
    $sumPath = Join-Path $Output "SHA256SUMS-v$Version.txt"
    [IO.File]::WriteAllText($sumPath, (($hashLines -join "`n") + "`n"), [Text.UTF8Encoding]::new($false))
    $githubAssetNames = @{
        "TextNodeAssistant-v$Version-$PortableSuffix.zip" = "TextNodeAssistant-v$Version-portable.zip"
        "TextNodeAssistant-v$Version-$ReleaseNotesSuffix.md" = "TextNodeAssistant-v$Version-release-notes-zh-CN.md"
        "TextNodeAssistant-v$Version-$BeginnerGuideSuffix.md" = "TextNodeAssistant-v$Version-beginner-guide-zh-CN.md"
        "TextNodeAssistant-v$Version-$ManualSuffix.md" = "TextNodeAssistant-v$Version-manual-zh-CN.md"
    }
    $githubHashLines = foreach ($name in $releaseNames) {
        $path = Join-Path $Output $name
        $hash = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
        $githubName = if ($githubAssetNames.ContainsKey($name)) { $githubAssetNames[$name] } else { $name }
        "$hash  $githubName"
    }
    $githubSumPath = Join-Path $Output "SHA256SUMS-GITHUB-v$Version.txt"
    [IO.File]::WriteAllText($githubSumPath, (($githubHashLines -join "`n") + "`n"), [Text.UTF8Encoding]::new($false))
    $releasePaths = @($releaseNames | ForEach-Object { Join-Path $Output $_ }) + @($sumPath, $githubSumPath)
    Get-Item -LiteralPath $releasePaths | Select-Object Name, Length
} finally {
    $resolvedRoot = [IO.Path]::GetFullPath($Root).TrimEnd('\') + '\'
    $resolvedStage = [IO.Path]::GetFullPath($Stage)
    if ((Test-Path -LiteralPath $Stage) -and $resolvedStage.StartsWith($resolvedRoot, [StringComparison]::OrdinalIgnoreCase)) {
        Remove-Item -LiteralPath $Stage -Recurse -Force
    }
}
