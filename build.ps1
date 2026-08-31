param(
    [ValidateSet("amd64", "386", "arm64")]
    [string]$Architecture = "amd64",
    [switch]$SkipCommonValidation,
    [switch]$SkipRuntimeSmoke
)

$ErrorActionPreference = "Stop"

$architectureInfo = switch ($Architecture) {
    "amd64" { @{ Suffix = "win64"; CscPlatform = "x64"; Friendly = "Windows x64" } }
    "386" { @{ Suffix = "win32"; CscPlatform = "x86"; Friendly = "Windows x86" } }
    "arm64" { @{ Suffix = "win-arm64"; CscPlatform = "anycpu"; Friendly = "Windows ARM64" } }
}

$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$RunbookRoot = Join-Path $Root "runbook"
$Archive = Join-Path $Root "assets\text-node-assistant-toolkit-v0.9.5.tar.gz"
$Dist = Join-Path $Root "dist"
$CliExe = Join-Path $Dist "TextNodeAssistant-v0.9.5-cli-$($architectureInfo.Suffix).exe"
$AskPassExe = Join-Path $Dist "TextNodeAssistant-v0.9.5-askpass-$($architectureInfo.Suffix).exe"
$GuiExe = Join-Path $Dist "TextNodeAssistant-v0.9.5-$($architectureInfo.Suffix).exe"
$GuiPreview = Join-Path $Dist "TextNodeAssistant-v0.9.5-gui-preview.png"
$OperationPreview = Join-Path $Dist "TextNodeAssistant-v0.9.5-workflow-preview.png"
$GuiSource = Join-Path $Root "gui\TextNodeAssistant.Gui.cs"
$AskPassSource = Join-Path $Root "gui\TextNodeAssistant.AskPass.cs"
$GuiXaml = Join-Path $Root "gui\MainWindow.xaml"
$GuiManifest = Join-Path $Root "gui\app.manifest"
$GuiIcon = Join-Path $Root "gui\TextNodeAssistant-v0.9.5.ico"
$GuiIconPng = Join-Path $Root "gui\TextNodeAssistant-v0.9.5-app-icon.png"

$Go = if ($env:PNA_GO_EXE) { $env:PNA_GO_EXE } else { "go" }
$Gofmt = if ($env:PNA_GOFMT_EXE) { $env:PNA_GOFMT_EXE } else { "gofmt" }
$Bash = if ($env:PNA_BASH_EXE) {
    $env:PNA_BASH_EXE
} elseif (Test-Path -LiteralPath "C:\Program Files\Git\bin\bash.exe") {
    "C:\Program Files\Git\bin\bash.exe"
} else {
    "bash"
}
$Csc = if ($env:PNA_CSC_EXE) {
    $env:PNA_CSC_EXE
} elseif (Test-Path -LiteralPath "$env:WINDIR\Microsoft.NET\Framework64\v4.0.30319\csc.exe") {
    "$env:WINDIR\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
} else {
    "$env:WINDIR\Microsoft.NET\Framework\v4.0.30319\csc.exe"
}

New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Archive), $Dist | Out-Null
foreach ($requiredVisual in @($GuiIcon, $GuiIconPng)) {
    if (-not (Test-Path -LiteralPath $requiredVisual -PathType Leaf)) {
        throw "Required application icon is missing: $requiredVisual"
    }
}
$RunbookPackageRoot = Join-Path $RunbookRoot "text-node-assistant-v0.9.5"
if (-not $SkipCommonValidation) {
    $RunbookHashManifest = Join-Path $RunbookPackageRoot "SHA256SUMS.txt"
    $runbookHashLines = Get-ChildItem -LiteralPath $RunbookPackageRoot -File -Recurse | Where-Object {
        $_.FullName -ne $RunbookHashManifest
    } | Sort-Object FullName | ForEach-Object {
        $relative = $_.FullName.Substring($RunbookPackageRoot.Length + 1).Replace('\', '/')
        $hash = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
        "$hash  $relative"
    }
    [IO.File]::WriteAllText($RunbookHashManifest, (($runbookHashLines -join "`n") + "`n"), [Text.UTF8Encoding]::new($false))
    & tar -czf $Archive -C $RunbookRoot "text-node-assistant-v0.9.5"
    if ($LASTEXITCODE -ne 0) { throw "tar failed" }

    # Windows and Android must ship the exact same toolkit bytes.  Rebuilding
    # the tarball changes the gzip stream even when its logical contents are
    # unchanged, so refresh the Android asset before cross-platform guards run.
    $AndroidToolkitAsset = Join-Path $Root "android\app\src\main\assets\text-node-assistant-toolkit-v0.9.5.tgz"
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $AndroidToolkitAsset) | Out-Null
    Copy-Item -LiteralPath $Archive -Destination $AndroidToolkitAsset -Force

    foreach ($shellTest in @(
        "scripts/validate-shell.sh",
        "scripts/test-diagnosis-protocol.sh",
        "scripts/test-xui-api-context.sh",
        "scripts/test-warp-route-idempotency.sh",
        "scripts/test-gui-remote-prompt.sh"
    )) {
        & $Bash $shellTest
        if ($LASTEXITCODE -ne 0) { throw "Shell validation failed: $shellTest" }
    }

    foreach ($staticTest in @(
        "scripts/test-feature-retirement-static.ps1",
        "scripts/test-reset-core-install-modes-static.ps1",
        "scripts/test-android-reset-static.ps1"
    )) {
        & powershell -NoProfile -ExecutionPolicy Bypass -File $staticTest
        if ($LASTEXITCODE -ne 0) { throw "Static reset-line validation failed: $staticTest" }
    }

    $GoFiles = Get-ChildItem -LiteralPath $Root -File -Filter "*.go" | ForEach-Object FullName
    & $Gofmt -w @GoFiles
    if ($LASTEXITCODE -ne 0) { throw "gofmt failed" }
}

Push-Location $Root
try {
    if (-not $SkipCommonValidation) {
        & $Go test ./...
        if ($LASTEXITCODE -ne 0) { throw "go test failed" }

        & $Go vet ./...
        if ($LASTEXITCODE -ne 0) { throw "go vet failed" }
    }

    $env:CGO_ENABLED = "0"
    $env:GOOS = "windows"
    $env:GOARCH = $Architecture
    Write-Host "Building $($architectureInfo.Friendly) workflow core..."
    & $Go build -trimpath -ldflags "-s -w" -o $CliExe .
    if ($LASTEXITCODE -ne 0) { throw "Go CLI build failed" }

    if (-not (Test-Path -LiteralPath $Csc -PathType Leaf)) {
        throw "64-bit .NET Framework C# compiler was not found: $Csc"
    }
    $frameworkDir = Split-Path -Parent $Csc
    $wpfDir = Join-Path $frameworkDir "WPF"
    $references = @(
        (Join-Path $frameworkDir "System.dll"),
        (Join-Path $frameworkDir "System.Core.dll"),
        (Join-Path $frameworkDir "System.Xml.dll"),
        (Join-Path $frameworkDir "System.Xaml.dll"),
        (Join-Path $wpfDir "WindowsBase.dll"),
        (Join-Path $wpfDir "PresentationCore.dll"),
        (Join-Path $wpfDir "PresentationFramework.dll")
    )
    foreach ($reference in $references) {
        if (-not (Test-Path -LiteralPath $reference -PathType Leaf)) {
            throw "Required .NET Framework assembly was not found: $reference"
        }
    }
    $askPassArguments = @(
        "/nologo", "/target:winexe", "/platform:$($architectureInfo.CscPlatform)", "/optimize+", "/debug-",
        "/out:$AskPassExe",
        "/reference:$(Join-Path $frameworkDir 'System.dll')",
        "/reference:$(Join-Path $frameworkDir 'System.Core.dll')",
        $AskPassSource
    )
    & $Csc @askPassArguments
    if ($LASTEXITCODE -ne 0) { throw "SSH AskPass helper build failed" }
    if ((Get-Item -LiteralPath $AskPassExe).Length -lt 4096) {
        throw "SSH AskPass helper is unexpectedly small"
    }
    if (-not $SkipRuntimeSmoke) {
        & (Join-Path $Root "scripts\test-askpass.ps1") -AskPassExe $AskPassExe
        if ($LASTEXITCODE -ne 0) { throw "SSH AskPass named-pipe smoke test failed" }
    }
    $arguments = @(
        "/nologo", "/target:winexe", "/platform:$($architectureInfo.CscPlatform)", "/optimize+", "/debug-",
        "/out:$GuiExe", "/win32manifest:$GuiManifest", "/win32icon:$GuiIcon",
        "/resource:$GuiXaml,ProxyNodeAssistant.MainWindow.xaml",
        "/resource:$GuiIconPng,ProxyNodeAssistant.AppIcon.png",
        "/resource:$CliExe,ProxyNodeAssistant.Cli.exe",
        "/resource:$AskPassExe,ProxyNodeAssistant.AskPass.exe"
    )
    $arguments += $references | ForEach-Object { "/reference:$_" }
    $arguments += $GuiSource
    & $Csc @arguments
    if ($LASTEXITCODE -ne 0) { throw "WPF GUI build failed" }

    if ((Get-Item -LiteralPath $GuiExe).Length -le (Get-Item -LiteralPath $CliExe).Length) {
        throw "GUI EXE is too small to contain the embedded CLI"
    }

    if (-not $SkipRuntimeSmoke) {
        $previewProcess = Start-Process -FilePath $GuiExe -ArgumentList @("--render-preview", ('"' + $GuiPreview + '"')) -PassThru -Wait
        if ($previewProcess.ExitCode -ne 0) {
            throw "GUI render smoke test failed with exit code $($previewProcess.ExitCode)"
        }
        if (-not (Test-Path -LiteralPath $GuiPreview -PathType Leaf) -or (Get-Item -LiteralPath $GuiPreview).Length -lt 50000) {
            throw "GUI render smoke test produced an empty or incomplete preview"
        }
        $workflowPreviewProcess = Start-Process -FilePath $GuiExe -ArgumentList @("--render-operation-preview", ('"' + $OperationPreview + '"')) -PassThru -Wait
        if ($workflowPreviewProcess.ExitCode -ne 0) {
            throw "GUI workflow render smoke test failed with exit code $($workflowPreviewProcess.ExitCode)"
        }
        if (-not (Test-Path -LiteralPath $OperationPreview -PathType Leaf) -or (Get-Item -LiteralPath $OperationPreview).Length -lt 50000) {
            throw "GUI workflow render smoke test produced an empty or incomplete preview"
        }
        $workflowSmoke = Start-Process -FilePath $GuiExe -ArgumentList @("--workflow-smoke") -PassThru
        if (-not $workflowSmoke.WaitForExit(30000)) {
            try { $workflowSmoke.Kill() } catch { }
            throw "Fully graphical local workflow smoke test timed out"
        }
        if ($workflowSmoke.ExitCode -ne 0) {
            throw "Fully graphical local workflow smoke test failed with exit code $($workflowSmoke.ExitCode)"
        }
        $promptSequenceSmoke = Start-Process -FilePath $GuiExe -ArgumentList @("--prompt-sequence-smoke") -PassThru
        if (-not $promptSequenceSmoke.WaitForExit(15000)) {
            try { $promptSequenceSmoke.Kill() } catch { }
            throw "GUI multi-step prompt protocol smoke test timed out"
        }
        if ($promptSequenceSmoke.ExitCode -ne 0) {
            throw "GUI multi-step prompt protocol smoke test failed with exit code $($promptSequenceSmoke.ExitCode)"
        }
        $inputCloseSmoke = Start-Process -FilePath $GuiExe -ArgumentList @("--input-close-smoke") -PassThru
        if (-not $inputCloseSmoke.WaitForExit(15000)) {
            try { $inputCloseSmoke.Kill() } catch { }
            throw "GUI closed-input anti-busy-loop smoke test timed out"
        }
        if ($inputCloseSmoke.ExitCode -ne 0) {
            throw "GUI closed-input anti-busy-loop smoke test failed with exit code $($inputCloseSmoke.ExitCode)"
        }
        $guiAskPassSmoke = Start-Process -FilePath $GuiExe -ArgumentList @("--askpass-smoke") -PassThru
        if (-not $guiAskPassSmoke.WaitForExit(15000)) {
            try { $guiAskPassSmoke.Kill() } catch { }
            throw "GUI secured AskPass smoke test timed out"
        }
        if ($guiAskPassSmoke.ExitCode -ne 0) {
            throw "GUI secured AskPass smoke test failed with exit code $($guiAskPassSmoke.ExitCode)"
        }
        $tunnelLifetimeSmoke = Start-Process -FilePath $GuiExe -ArgumentList @("--tunnel-lifetime-smoke") -PassThru
        if (-not $tunnelLifetimeSmoke.WaitForExit(15000)) {
            try { $tunnelLifetimeSmoke.Kill() } catch { }
            throw "GUI panel-tunnel lifetime smoke test timed out"
        }
        if ($tunnelLifetimeSmoke.ExitCode -ne 0) {
            throw "GUI panel-tunnel lifetime smoke test failed with exit code $($tunnelLifetimeSmoke.ExitCode)"
        }
        $historySmokePath = Join-Path $env:TEMP ("pna-history-smoke-" + [Guid]::NewGuid().ToString("N") + ".tsv")
        try {
            $historySmoke = Start-Process -FilePath $GuiExe -ArgumentList @("--history-smoke", ('"' + $historySmokePath + '"')) -PassThru
            if (-not $historySmoke.WaitForExit(15000)) {
                try { $historySmoke.Kill() } catch { }
                throw "GUI recent-target history smoke test timed out"
            }
            if ($historySmoke.ExitCode -ne 0) {
                throw "GUI recent-target startup smoke test failed with exit code $($historySmoke.ExitCode)"
            }
        } finally {
            if (Test-Path -LiteralPath $historySmokePath) { Remove-Item -LiteralPath $historySmokePath -Force }
        }
    } else {
        Write-Host "Runtime smoke tests skipped for $($architectureInfo.Friendly); cross-compiled binary was statically validated."
    }
} finally {
    Pop-Location
}

Get-FileHash -Algorithm SHA256 $GuiExe
