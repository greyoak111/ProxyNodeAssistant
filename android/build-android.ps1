param(
    [ValidateSet("Debug", "Release", "Test")]
    [string]$Task = "Debug",
    [switch]$Provision
)

$ErrorActionPreference = "Stop"
$projectRoot = Split-Path -Parent $PSScriptRoot
$toolsRoot = if ($env:PNA_ANDROID_TOOLS_ROOT) {
    [IO.Path]::GetFullPath($env:PNA_ANDROID_TOOLS_ROOT)
} else {
    Join-Path $projectRoot ".android-tools"
}
$jdkRoot = Join-Path $toolsRoot "jdk-17"
$sdkRoot = Join-Path $toolsRoot "sdk"
$gradleRoot = Join-Path $toolsRoot "gradle-9.5.0"
$toolkitSource = Join-Path $projectRoot "assets\proxy-node-assistant-toolkit-v1.0.0.tar.gz"
$toolkitAssetDirectory = Join-Path $PSScriptRoot "app\src\main\assets"
$toolkitAsset = Join-Path $toolkitAssetDirectory "proxy-node-assistant-toolkit-v1.0.0.tgz"

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

if (-not (Test-Path -LiteralPath $toolkitSource)) {
    throw "Missing current ProxyNodeAssistant toolkit archive: $toolkitSource. Run the repository build first."
}
if ((Get-Item -LiteralPath $toolkitSource).Length -le 128) {
    throw "Current ProxyNodeAssistant toolkit archive is unexpectedly empty: $toolkitSource"
}
$toolkitEntries = @(& tar -tzf $toolkitSource)
if ($LASTEXITCODE -ne 0 -or $toolkitEntries.Count -eq 0) {
    throw "Could not inspect the current ProxyNodeAssistant toolkit archive"
}
if ($toolkitEntries | Where-Object { $_ -notlike "proxy-node-assistant-v1.0.0/*" }) {
    throw "Current toolkit archive has a stale or unexpected top-level directory; rebuild the repository archive first"
}
$requiredToolkitEntries = @(
    # Release metadata and the complete non-retired surface used by the
    # Android workflow probe.  Keeping this list here (rather than checking
    # only the bootstrap script) prevents an apparently successful APK build
    # from carrying an archive that will fail TOOLKIT_COMPLETE after upload.
    "proxy-node-assistant-v1.0.0/TOOLKIT_VERSION",
    "proxy-node-assistant-v1.0.0/THIRD_PARTY_LOCK.env",
    "proxy-node-assistant-v1.0.0/TOOLKIT_BUILD_ID",
    "proxy-node-assistant-v1.0.0/TOOLKIT_BUILD_REVISION",
    "proxy-node-assistant-v1.0.0/linux/00-bootstrap-toolkit.sh",
    "proxy-node-assistant-v1.0.0/linux/00-preflight-vps.sh",
    "proxy-node-assistant-v1.0.0/linux/00-migrate-legacy-state.sh",
    "proxy-node-assistant-v1.0.0/linux/00-auto-install-or-optimize.sh",
    # This one-shot file only retires old v0.9.x state.  It is not an active
    # device-admission, drive, or Copyparty feature, but remains required so
    # an upgrade can finish its guarded cleanup step.
    "proxy-node-assistant-v1.0.0/linux/00c-retire-v095-device-drive.sh",
    "proxy-node-assistant-v1.0.0/linux/01-safe-backup.sh",
    "proxy-node-assistant-v1.0.0/linux/01a-rotate-vps-password.sh",
    "proxy-node-assistant-v1.0.0/linux/02-install-base.sh",
    "proxy-node-assistant-v1.0.0/linux/02b-firewall-safe.sh",
    "proxy-node-assistant-v1.0.0/linux/03-install-3xui.sh",
    "proxy-node-assistant-v1.0.0/linux/03b-lockdown-panel.sh",
    "proxy-node-assistant-v1.0.0/linux/03c-rotate-panel-credentials.sh",
    "proxy-node-assistant-v1.0.0/linux/03d-export-panel-handoff.sh",
    "proxy-node-assistant-v1.0.0/linux/04-generate-reality.sh",
    "proxy-node-assistant-v1.0.0/linux/04a-reality-api.sh",
    "proxy-node-assistant-v1.0.0/linux/04b-open-test-port-current-ssh.sh",
    "proxy-node-assistant-v1.0.0/linux/04c-close-test-port.sh",
    "proxy-node-assistant-v1.0.0/linux/04d-optimize-existing-reality-shadow.sh",
    "proxy-node-assistant-v1.0.0/linux/04e-export-reality-handoff.sh",
    "proxy-node-assistant-v1.0.0/linux/04f-xhttp-cdn-api.sh",
    "proxy-node-assistant-v1.0.0/linux/05-cover-bootstrap.sh",
    "proxy-node-assistant-v1.0.0/linux/05a-cloudflare-dns-upsert.sh",
    "proxy-node-assistant-v1.0.0/linux/05b-cover-site-polished.sh",
    "proxy-node-assistant-v1.0.0/linux/05c-optimize-cover-backend.sh",
    "proxy-node-assistant-v1.0.0/linux/05d-configure-subscription.sh",
    "proxy-node-assistant-v1.0.0/linux/05e-cdn-xhttp-nginx.sh",
    "proxy-node-assistant-v1.0.0/linux/05f-cloudflare-origin-lock.sh",
    "proxy-node-assistant-v1.0.0/linux/05g-cdn-xhttp-validate.sh",
    "proxy-node-assistant-v1.0.0/linux/05h-ensure-cdn-certificate.sh",
    "proxy-node-assistant-v1.0.0/linux/06-warp-install.sh",
    "proxy-node-assistant-v1.0.0/linux/07-warp-configure-proxy.sh",
    "proxy-node-assistant-v1.0.0/linux/07a-apply-warp-route-local.sh",
    "proxy-node-assistant-v1.0.0/linux/08-warp-check.sh",
    "proxy-node-assistant-v1.0.0/linux/09-status-node.sh",
    "proxy-node-assistant-v1.0.0/linux/10-emergency-network-dump.sh",
    "proxy-node-assistant-v1.0.0/linux/11-safe-upgrade-audit.sh",
    "proxy-node-assistant-v1.0.0/linux/12-restore-iptables-vnc-only.sh",
    "proxy-node-assistant-v1.0.0/linux/13-maintenance-menu.sh",
    "proxy-node-assistant-v1.0.0/linux/14-node-doctor.sh",
    "proxy-node-assistant-v1.0.0/linux/15-show-current-node.sh",
    "proxy-node-assistant-v1.0.0/linux/16-auto-diagnose.sh",
    "proxy-node-assistant-v1.0.0/linux/17-safe-auto-repair.sh",
    "proxy-node-assistant-v1.0.0/linux/18-panel-metadata.sh",
    "proxy-node-assistant-v1.0.0/linux/19-prune-backups-current-config.sh",
    "proxy-node-assistant-v1.0.0/linux/20-adaptive-performance.sh",
    "proxy-node-assistant-v1.0.0/linux/21-traffic-status.sh",
    "proxy-node-assistant-v1.0.0/linux/22-dismantle-managed-node.sh",
    "proxy-node-assistant-v1.0.0/linux/23-node-identity.sh",
    "proxy-node-assistant-v1.0.0/linux/23-ss2022-tcp.sh",
    "proxy-node-assistant-v1.0.0/linux/24-security-baseline.sh",
    "proxy-node-assistant-v1.0.0/linux/25-security-events.sh",
    "proxy-node-assistant-v1.0.0/linux/27-ip-rebind.sh",
    "proxy-node-assistant-v1.0.0/linux/28-topology-reconcile.sh",
    "proxy-node-assistant-v1.0.0/linux/28a-install-transaction.sh",
    "proxy-node-assistant-v1.0.0/linux/32-subscription-rewrite.py",
    "proxy-node-assistant-v1.0.0/linux/lib-deployment-state.sh",
    "proxy-node-assistant-v1.0.0/linux/lib-dns-quorum.sh",
    "proxy-node-assistant-v1.0.0/linux/lib-gui-prompt.sh",
    "proxy-node-assistant-v1.0.0/linux/lib-handoff.sh",
    "proxy-node-assistant-v1.0.0/linux/lib-third-party.sh",
    "proxy-node-assistant-v1.0.0/linux/lib-xui-api.sh",
    # Runtime cover/subscription assets used by 05b/05d and the topology
    # reconciler.  The retired marker is documentation only and is omitted.
    "proxy-node-assistant-v1.0.0/templates/NODE_REGISTRY.csv",
    "proxy-node-assistant-v1.0.0/templates/cover-sites/MANIFEST.tsv",
    "proxy-node-assistant-v1.0.0/templates/cover-sites/01-atlas-journal.html",
    "proxy-node-assistant-v1.0.0/templates/cover-sites/02-northstar-studio.html",
    "proxy-node-assistant-v1.0.0/templates/cover-sites/03-cedar-stone.html",
    "proxy-node-assistant-v1.0.0/templates/cover-sites/04-field-lab.html",
    "proxy-node-assistant-v1.0.0/templates/cover-sites/05-harbor-weather.html",
    "proxy-node-assistant-v1.0.0/templates/cover-sites/06-local-library.html",
    "proxy-node-assistant-v1.0.0/templates/cover-sites/07-ember-cafe.html",
    "proxy-node-assistant-v1.0.0/templates/cover-sites/08-trail-guide.html",
    "proxy-node-assistant-v1.0.0/templates/cover-sites/09-signal-status.html",
    "proxy-node-assistant-v1.0.0/templates/cover-sites/10-mono-docs.html",
    "proxy-node-assistant-v1.0.0/templates/cover-sites/11-analog-radio.html",
    "proxy-node-assistant-v1.0.0/templates/cover-sites/12-city-calendar.html",
    "proxy-node-assistant-v1.0.0/templates/cover-sites/13-pixel-gallery.html",
    "proxy-node-assistant-v1.0.0/templates/cover-sites/14-quiet-finance.html",
    "proxy-node-assistant-v1.0.0/templates/cover-sites/15-signal-runner.html",
    "proxy-node-assistant-v1.0.0/templates/systemd/proxy-node-assistant-subscription-proxy.service"
)
foreach ($entry in $requiredToolkitEntries) {
    if ($toolkitEntries -notcontains $entry) {
        throw "Current toolkit archive is missing an Android fresh-install entry: $entry"
    }
}
# A retirement note and the one-shot 00c cleanup helper are allowed.  Any
# active admission/drive/Copyparty path indicates that a stale archive was
# assembled and must never be embedded into the client.
$unexpectedRetiredEntries = @($toolkitEntries | Where-Object {
    $_ -match '(?i)(^|/)26[^/]*(device|admission)|(^|/)(copyparty|private-drive|drive-credential)(/|\.|$)'
} | Where-Object { $_ -notmatch '(?i)00c-retire-v095-device-drive\.sh$' })
if ($unexpectedRetiredEntries.Count -gt 0) {
    throw "Current toolkit archive contains retired active entries: $($unexpectedRetiredEntries -join ', ')"
}
$archiveVersion = (& tar -xOf $toolkitSource "proxy-node-assistant-v1.0.0/TOOLKIT_VERSION" | Out-String).Trim()
$archiveBuildId = (& tar -xOf $toolkitSource "proxy-node-assistant-v1.0.0/TOOLKIT_BUILD_ID" | Out-String).Trim()
$archiveBuildRevision = (& tar -xOf $toolkitSource "proxy-node-assistant-v1.0.0/TOOLKIT_BUILD_REVISION" | Out-String).Trim()
if ($archiveVersion -ne "1.0.0" -or $archiveBuildId -ne "20260901-v100-ss2022-r105" -or $archiveBuildRevision -ne "105") {
    throw "Current toolkit archive metadata is not the exact ProxyNodeAssistant v1.0.0 revision-105 build"
}
New-Item -ItemType Directory -Force -Path $toolkitAssetDirectory | Out-Null
Copy-Item -LiteralPath $toolkitSource -Destination $toolkitAsset -Force
if ((Get-FileHash -Algorithm SHA256 -LiteralPath $toolkitSource).Hash -ne (Get-FileHash -Algorithm SHA256 -LiteralPath $toolkitAsset).Hash) {
    throw "Embedded Android toolkit asset does not match the current repository archive"
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
