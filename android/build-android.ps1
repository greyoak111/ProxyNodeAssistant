param(
    [ValidateSet("Debug", "Release", "Test")]
    [string]$Task = "Debug",
    [switch]$Provision
)

$ErrorActionPreference = "Stop"
$projectRoot = Split-Path -Parent $PSScriptRoot
$toolsRoot = Join-Path $projectRoot ".android-tools"
$jdkRoot = Join-Path $toolsRoot "jdk-17"
$sdkRoot = Join-Path $toolsRoot "sdk"
$gradleRoot = Join-Path $toolsRoot "gradle-9.5.0"

function Get-VerifiedFile {
    param([string]$Uri, [string]$Destination, [string]$ExpectedSha256 = "")
    if (-not (Test-Path -LiteralPath $Destination)) {
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Destination) | Out-Null
        Invoke-WebRequest -UseBasicParsing -Uri $Uri -OutFile $Destination
    }
    if ($ExpectedSha256) {
        $actual = (Get-FileHash -Algorithm SHA256 -LiteralPath $Destination).Hash.ToLowerInvariant()
        if ($actual -ne $ExpectedSha256.ToLowerInvariant()) { throw "SHA-256 mismatch for $Destination" }
    }
}

function Expand-CleanArchive {
    param([string]$Archive, [string]$Destination)
    if (Test-Path -LiteralPath $Destination) { return }
    $temporary = "$Destination.extracting"
    if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Recurse -Force }
    New-Item -ItemType Directory -Force -Path $temporary | Out-Null
    Expand-Archive -LiteralPath $Archive -DestinationPath $temporary -Force
    Move-Item -LiteralPath $temporary -Destination $Destination
}

if ($Provision) {
    New-Item -ItemType Directory -Force -Path $toolsRoot | Out-Null

    $jdkArchive = Join-Path $toolsRoot "microsoft-jdk-17-windows-x64.zip"
    Get-VerifiedFile "https://aka.ms/download-jdk/microsoft-jdk-17-windows-x64.zip" $jdkArchive
    if (-not (Test-Path -LiteralPath $jdkRoot)) {
        $jdkExtract = Join-Path $toolsRoot "jdk-extract"
        if (Test-Path -LiteralPath $jdkExtract) { Remove-Item -LiteralPath $jdkExtract -Recurse -Force }
        Expand-Archive -LiteralPath $jdkArchive -DestinationPath $jdkExtract -Force
        $jdkChild = Get-ChildItem -LiteralPath $jdkExtract -Directory | Select-Object -First 1
        Move-Item -LiteralPath $jdkChild.FullName -Destination $jdkRoot
        Remove-Item -LiteralPath $jdkExtract -Recurse -Force
    }

    $gradleArchive = Join-Path $toolsRoot "gradle-9.5.0-bin.zip"
    $gradleChecksum = Join-Path $toolsRoot "gradle-9.5.0-bin.zip.sha256"
    Get-VerifiedFile "https://services.gradle.org/distributions/gradle-9.5.0-bin.zip.sha256" $gradleChecksum
    $expectedGradle = (Get-Content -LiteralPath $gradleChecksum -Raw).Trim().Split(' ')[0]
    Get-VerifiedFile "https://services.gradle.org/distributions/gradle-9.5.0-bin.zip" $gradleArchive $expectedGradle
    if (-not (Test-Path -LiteralPath $gradleRoot)) {
        Expand-Archive -LiteralPath $gradleArchive -DestinationPath $toolsRoot -Force
    }

    $commandToolsArchive = Join-Path $toolsRoot "commandlinetools-win-15859902_latest.zip"
    Get-VerifiedFile "https://dl.google.com/android/repository/commandlinetools-win-15859902_latest.zip" $commandToolsArchive "90ae805d20434428bffcb699c290860f19bb5f66a67e6b330067e3de801fb04a"
    $latestTools = Join-Path $sdkRoot "cmdline-tools\latest"
    if (-not (Test-Path -LiteralPath $latestTools)) {
        $toolExtract = Join-Path $toolsRoot "command-tools-extract"
        if (Test-Path -LiteralPath $toolExtract) { Remove-Item -LiteralPath $toolExtract -Recurse -Force }
        Expand-Archive -LiteralPath $commandToolsArchive -DestinationPath $toolExtract -Force
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $latestTools) | Out-Null
        Move-Item -LiteralPath (Join-Path $toolExtract "cmdline-tools") -Destination $latestTools
        Remove-Item -LiteralPath $toolExtract -Recurse -Force
    }

    $env:JAVA_HOME = $jdkRoot
    $sdkManager = Join-Path $latestTools "bin\sdkmanager.bat"
    1..40 | ForEach-Object { "y" } | & $sdkManager --sdk_root=$sdkRoot --licenses | Out-Host
    & $sdkManager --sdk_root=$sdkRoot "platform-tools" "platforms;android-37.0" "build-tools;36.0.0" | Out-Host
}

foreach ($required in @((Join-Path $jdkRoot "bin\java.exe"), (Join-Path $gradleRoot "bin\gradle.bat"), (Join-Path $sdkRoot "platforms\android-37.0\android.jar"))) {
    if (-not (Test-Path -LiteralPath $required)) { throw "Missing Android build dependency: $required. Run with -Provision once." }
}

$env:JAVA_HOME = $jdkRoot
$env:ANDROID_HOME = $sdkRoot
$env:ANDROID_SDK_ROOT = $sdkRoot
$escapedSdk = $sdkRoot.Replace('\', '\\').Replace(':', '\:')
Set-Content -LiteralPath (Join-Path $PSScriptRoot "local.properties") -Value "sdk.dir=$escapedSdk" -Encoding ascii

$gradle = Join-Path $gradleRoot "bin\gradle.bat"
$gradleTask = switch ($Task) {
    "Debug" { ":app:assembleDebug" }
    "Release" { ":app:assembleRelease" }
    "Test" { ":app:testDebugUnitTest" }
}
Push-Location $PSScriptRoot
try {
    & $gradle --no-daemon --stacktrace $gradleTask
    if ($LASTEXITCODE -ne 0) { throw "Gradle failed with exit code $LASTEXITCODE" }
} finally {
    Pop-Location
}
