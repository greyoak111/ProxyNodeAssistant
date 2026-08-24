$ErrorActionPreference = "Stop"

Add-Type -AssemblyName System.IO.Compression.FileSystem

$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$Workspace = Split-Path -Parent (Split-Path -Parent $Root)
$Output = if ($env:PNA_PACKAGE_OUTPUT) { [IO.Path]::GetFullPath($env:PNA_PACKAGE_OUTPUT) } else { Join-Path $Workspace "outputs" }
$Version = "0.9.5"
$ToolkitVersion = "0.9.5"
$ManualSuffix = -join ([char[]]@(0x5B8C, 0x6574, 0x4F7F, 0x7528, 0x8BF4, 0x660E, 0x4E66))
$BeginnerGuideSuffix = -join ([char[]]@(0x4ECE, 0x96F6, 0x90E8, 0x7F72, 0x6559, 0x7A0B))
$ReleaseNotesSuffix = -join ([char[]]@(0x66F4, 0x65B0, 0x8BF4, 0x660E))
$PortableSuffix = -join ([char[]]@(0x4FBF, 0x643A, 0x5305))
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
    $manual = Join-Path $Root "ProxyNodeAssistant-v$Version-$ManualSuffix.md"
    $beginnerGuide = Join-Path $Root "ProxyNodeAssistant-v$Version-$BeginnerGuideSuffix.md"
    $notes = Join-Path $Root "ProxyNodeAssistant-v$Version-$ReleaseNotesSuffix.md"
    $readme = Join-Path $Root "README.md"
    $license = Join-Path $Root "LICENSE"
    $androidManual = Join-Path $Root "ANDROID.md"
    $androidManualName = "ProxyNodeAssistant-v$Version-android-manual-zh-CN.md"
    $androidApk = Join-Path $Root "android\dist\ProxyNodeAssistant-v$Version-android-universal.apk"
    $iconPng = Join-Path $Root "gui\ProxyNodeAssistant-v$Version-app-icon.png"
    $iconIco = Join-Path $Root "gui\ProxyNodeAssistant-v$Version.ico"
    foreach ($required in @($executables + @($preview, $workflowPreview, $toolkit, $manual, $beginnerGuide, $notes, $readme, $license, $androidManual, $iconPng, $iconIco))) {
        if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
            throw "Required release input is missing: $required"
        }
    }

    Copy-Item -LiteralPath ($executables + @($preview, $workflowPreview, $toolkit, $manual, $beginnerGuide, $notes, $readme, $license, $iconPng, $iconIco)) -Destination $Portable
    Copy-Item -LiteralPath $androidManual -Destination (Join-Path $Portable $androidManualName)
    if (Test-Path -LiteralPath $androidApk -PathType Leaf) {
        Copy-Item -LiteralPath $androidApk -Destination $Portable
    }

    Get-ChildItem -LiteralPath $Root -File | Where-Object {
        ($_.Extension -in @(".go", ".ps1", ".bat") -or $_.Name -in @("go.mod", "LICENSE")) -or
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
    Copy-Item -LiteralPath (Join-Path $Root "runbook\proxy-runbook-v$ToolkitVersion") -Destination $sourceRunbook -Recurse
    $sourceAssets = Join-Path $Source "assets"
    New-Item -ItemType Directory -Force -Path $sourceAssets, (Join-Path $Source "dist") | Out-Null
    Copy-Item -LiteralPath $toolkit -Destination $sourceAssets

    $portableZip = Join-Path $Output "ProxyNodeAssistant-v$Version-$PortableSuffix.zip"
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

    Copy-Item -LiteralPath ($executables + @($preview, $workflowPreview, $toolkit, $manual, $beginnerGuide, $notes, $iconPng, $iconIco)) -Destination $Output -Force
    Copy-Item -LiteralPath $androidManual -Destination (Join-Path $Output $androidManualName) -Force
    if (Test-Path -LiteralPath $androidApk -PathType Leaf) {
        Copy-Item -LiteralPath $androidApk -Destination $Output -Force
    }

    $releaseNames = @(
        "proxy-runbook-toolkit-v$ToolkitVersion.tar.gz",
        "ProxyNodeAssistant-v$Version-$PortableSuffix.zip",
        "ProxyNodeAssistant-v$Version-$ReleaseNotesSuffix.md",
        "ProxyNodeAssistant-v$Version-$BeginnerGuideSuffix.md",
        "ProxyNodeAssistant-v$Version-$ManualSuffix.md",
        $androidManualName,
        "ProxyNodeAssistant-v$Version-source.zip",
        "ProxyNodeAssistant-v$Version-win64.exe",
        "ProxyNodeAssistant-v$Version-win32.exe",
        "ProxyNodeAssistant-v$Version-win-arm64.exe",
        "ProxyNodeAssistant-v$Version-gui-preview.png",
        "ProxyNodeAssistant-v$Version-workflow-preview.png",
        "ProxyNodeAssistant-v$Version-app-icon.png",
        "ProxyNodeAssistant-v$Version.ico"
    )
    if (Test-Path -LiteralPath $androidApk -PathType Leaf) {
        $releaseNames += "ProxyNodeAssistant-v$Version-android-universal.apk"
    }
    $hashLines = foreach ($name in $releaseNames) {
        $path = Join-Path $Output $name
        $hash = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
        "$hash  $name"
    }
    $sumPath = Join-Path $Output "SHA256SUMS-v$Version.txt"
    [IO.File]::WriteAllText($sumPath, (($hashLines -join "`n") + "`n"), [Text.UTF8Encoding]::new($false))
    $githubAssetNames = @{
        "ProxyNodeAssistant-v$Version-$PortableSuffix.zip" = "ProxyNodeAssistant-v$Version-portable.zip"
        "ProxyNodeAssistant-v$Version-$ReleaseNotesSuffix.md" = "ProxyNodeAssistant-v$Version-release-notes-zh-CN.md"
        "ProxyNodeAssistant-v$Version-$BeginnerGuideSuffix.md" = "ProxyNodeAssistant-v$Version-beginner-guide-zh-CN.md"
        "ProxyNodeAssistant-v$Version-$ManualSuffix.md" = "ProxyNodeAssistant-v$Version-manual-zh-CN.md"
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
