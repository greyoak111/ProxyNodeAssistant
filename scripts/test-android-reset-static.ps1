$ErrorActionPreference = "Stop"

$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)

function Read-RepoFile([string]$relativePath) {
    $path = Join-Path $root $relativePath
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Missing required file: $relativePath"
    }
    return Get-Content -LiteralPath $path -Raw
}

function Assert-Match([string]$text, [string]$pattern, [string]$message) {
    if ($text -notmatch $pattern) { throw $message }
}

function Assert-NoMatch([string]$text, [string]$pattern, [string]$message) {
    if ($text -match $pattern) { throw $message }
}

$gradle = Read-RepoFile "android/app/build.gradle.kts"
Assert-Match $gradle 'namespace\s*=\s*"com\.proxynodeassistant\.android"' "Android namespace changed; legacy upgrade compatibility would break"
Assert-Match $gradle 'applicationId\s*=\s*"com\.proxynodeassistant\.android"' "Android applicationId changed; in-place upgrades would break"
Assert-Match $gradle 'versionCode\s*=\s*950100' "Android versionCode is not the v0.9.5 revision-100 code"
Assert-Match $gradle 'versionName\s*=\s*"0\.9\.5"' "Android visible version is not v0.9.5"

$workflow = Read-RepoFile "android/app/src/main/java/com/proxynodeassistant/android/remote/WorkflowRunner.kt"
Assert-Match $workflow 'const val VERSION = "0\.9\.5"' "Android workflow visible version is not v0.9.5"
Assert-Match $workflow 'const val BUILD_REVISION = 100' "Android workflow revision is not 100"
Assert-Match $workflow 'const val REMOTE_ROOT = "/opt/text-node-assistant-current"' "Android workflow does not use the current TextNodeAssistant remote root"
Assert-Match $workflow 'const val LEGACY_REMOTE_ROOT = "/opt/proxy-runbook-current"' "Android workflow lost the v0.9.0 remote-root migration probe"
Assert-Match $workflow 'const val TOOLKIT_ASSET = "text-node-assistant-toolkit-v0\.9\.5\.tgz"' "Android workflow does not reference the current embedded toolkit"
Assert-Match $workflow '!probe\.installed\s*->\s*true' "A completely fresh VPS no longer marks the embedded-toolkit upload as required"
Assert-Match $workflow 'if \(needsUpload\) \{[\s\S]*uploadToolkit\(handle\)' "The confirmed Android install plan no longer uploads the toolkit when required"
Assert-Match $workflow 'context\.assets\.open\(TOOLKIT_ASSET\)' "Android no longer reads the toolkit from its APK assets"
Assert-Match $workflow 'handle\.upload\(bytes, TOOLKIT_ARCHIVE, "/tmp", "0600"\)' "Android no longer uploads the embedded toolkit securely"
Assert-Match $workflow 'tar -xzf.*-C /opt.*00-bootstrap-toolkit\.sh' "Android fresh-install path no longer extracts and bootstraps the uploaded toolkit"
Assert-Match $workflow 'verified\.installed && verified\.complete && verified\.version == VERSION && verified\.buildId == BUILD_ID && verified\.buildRevision == BUILD_REVISION' "Android no longer verifies the exact installed toolkit build"
Assert-Match $workflow 'PromptKind\.EXACT_CONFIRMATION,[\s\S]*placeholder = "APPLY"' "Android action 1 no longer requires an exact APPLY after preview"
$applyGuardIndex = $workflow.IndexOf('if (apply != "APPLY")')
$uploadBranchIndex = $workflow.IndexOf('if (needsUpload)')
if ($applyGuardIndex -lt 0 -or $uploadBranchIndex -lt 0 -or $applyGuardIndex -ge $uploadBranchIndex) {
    throw "Android may upload the toolkit before the exact APPLY guard"
}
Assert-Match $workflow 'InstallRouteMode\.KEEP[\s\S]*InstallRouteMode\.GRAY[\s\S]*InstallRouteMode\.ORANGE[\s\S]*InstallRouteMode\.DUAL' "Android action 1 does not implement all four route outcomes"
Assert-Match $workflow 'TNA_TOPOLOGY_STAGED=1' "Android orange/dual route no longer verifies staged topology"
Assert-Match $workflow 'REAL BROWSE OK' "Android orange/dual route no longer requires a real client browse before commit"
Assert-Match $workflow 'TNA_TOPOLOGY_RECONCILED=1' "Android route reconciliation no longer verifies completion markers"
Assert-NoMatch $workflow 'PROXY_RUNBOOK_ASSUME_DEFAULTS' "Android action 1 silently enables unsafe runbook defaults"
Assert-NoMatch $workflow '/tmp/proxy-runbook-auto-input' "Android action 1 reintroduced the fixed legacy auto-input path"
Assert-Match $workflow 'text-node-assistant-auto-input-\$\{randomToken\(\)\}\.env' "Android action 1 no longer uses a randomized one-run input file"
Assert-Match $workflow 'handle\.upload\(installAutoInput\(plan\)\.toByteArray\(\), oneRunName, "/tmp", "0600"\)' "Android action 1 no longer uploads the randomized input with mode 0600"

$androidBuilder = Read-RepoFile "android/build-android.ps1"
Assert-Match $androidBuilder 'text-node-assistant-v0\.9\.5/linux/00-bootstrap-toolkit\.sh' "Android build no longer verifies the fresh-VPS bootstrap entry"
Assert-Match $androidBuilder 'text-node-assistant-v0\.9\.5/linux/28-topology-reconcile\.sh' "Android build no longer verifies the explicit route reconciler"
Assert-Match $androidBuilder '20260831-v095-reset-from-v090-r100' "Android build no longer verifies the exact toolkit build id"
Assert-Match $androidBuilder '\$archiveBuildRevision -ne "100"' "Android build no longer verifies toolkit revision 100"

$installPlan = Read-RepoFile "android/app/src/main/java/com/proxynodeassistant/android/remote/InstallPlan.kt"
foreach ($requiredPlanValue in @('TNA_ROUTE_MODE', 'TNA_PERFORMANCE_MODE', 'TNA_WARP_MODE', 'TNA_COVER_TEMPLATE', 'TNA_REALITY_PRODUCTION_PORT', 'TNA_REALITY_SHADOW_PORT', 'TNA_CDN_ORIGIN_PORT', 'TNA_WARP_LOOPBACK_PORT', 'TNA_PLAN_CONFIRMED', 'TNA_AUTO_INPUT')) {
    Assert-Match $installPlan ([regex]::Escape($requiredPlanValue)) "Android InstallPlan is missing explicit value $requiredPlanValue"
}

$vault = Read-RepoFile "android/app/src/main/java/com/proxynodeassistant/android/data/EncryptedVault.kt"
Assert-Match $vault 'keyAlias\s*=\s*"pna-v0\.9\.0-vault"' "Encrypted-vault alias changed; old Android secrets would become unreadable"

$signer = Read-RepoFile "android/build-signed-release.ps1"
Assert-Match $signer 'ProxyNodeAssistant\\android-signing' "Persistent Android signing directory changed"
Assert-Match $signer 'pna-release-v1\.jks' "Persistent Android keystore filename changed"
Assert-Match $signer '-alias pna-release-v1' "Persistent Android signing alias changed"
Assert-Match $signer 'TextNodeAssistant-v0\.9\.5-android-universal\.apk' "Signed APK artifact name is stale"

$packager = Read-RepoFile "package.ps1"
Assert-Match $packager '\$Version\s*=\s*"0\.9\.5"' "Package visible version is not v0.9.5"
Assert-Match $packager 'TextNodeAssistant-v\$Version-win64\.exe' "Package still expects a stale Windows executable name"
Assert-Match $packager 'text-node-assistant-toolkit-v\$ToolkitVersion\.tar\.gz' "Package still expects a stale toolkit archive name"
Assert-Match $packager '@\(\$preview, \$workflowPreview, \$toolkit, \$manual, \$beginnerGuide, \$notes, \$readme, \$license, \$androidManual, \$androidApk,' "Official packaging no longer requires the Android APK"
Assert-NoMatch $packager 'if \(Test-Path -LiteralPath \$androidApk' "Official packaging may silently omit the Android APK"
Assert-NoMatch $packager 'dist\\ProxyNodeAssistant-v|ProxyNodeAssistant-v0\.9\.0-android' "Package would publish a stale product artifact name"

$androidSources = Get-ChildItem -LiteralPath (Join-Path $root "android/app/src") -File -Recurse |
    ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw } |
    Out-String
Assert-NoMatch $androidSources '(?i)TNAINV|device.?admission|DriveShell|copyparty|local.?admin|first.?controller' "Removed v0.9.5 experimental admission/drive/admin code leaked into the reset Android client"
Assert-NoMatch $androidSources 'Proxy Node Assistant|PROXY NODE ASSISTANT' "A visible legacy Android product name remains"
Assert-Match $androidSources '<string name="app_name">TextNodeAssistant</string>' "Android launcher label is not TextNodeAssistant in every locale"

$oldRunbookReference = Get-ChildItem -LiteralPath (Join-Path $root "scripts") -File -Recurse |
    ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw } |
    Out-String
Assert-NoMatch $oldRunbookReference 'runbook[/\\]proxy-runbook-v0\.9\.0' "A validation script still targets the removed v0.9.0 source directory"

$toolkitArchive = Join-Path $root "assets/text-node-assistant-toolkit-v0.9.5.tar.gz"
$toolkitAsset = Join-Path $root "android/app/src/main/assets/text-node-assistant-toolkit-v0.9.5.tgz"
foreach ($path in @($toolkitArchive, $toolkitAsset)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf) -or (Get-Item -LiteralPath $path).Length -le 128) {
        throw "Missing or empty toolkit archive: $path"
    }
}
if ((Get-FileHash -Algorithm SHA256 -LiteralPath $toolkitArchive).Hash -ne (Get-FileHash -Algorithm SHA256 -LiteralPath $toolkitAsset).Hash) {
    throw "Android embedded toolkit does not match the PC release toolkit"
}
$archiveEntries = @(& tar -tzf $toolkitArchive)
if ($LASTEXITCODE -ne 0 -or $archiveEntries.Count -eq 0) { throw "Could not inspect the current toolkit archive" }
if ($archiveEntries | Where-Object { $_ -notlike 'text-node-assistant-v0.9.5/*' }) {
    throw "Toolkit archive contains a stale or unexpected top-level directory"
}
foreach ($entry in @(
    'text-node-assistant-v0.9.5/TOOLKIT_VERSION',
    'text-node-assistant-v0.9.5/TOOLKIT_BUILD_ID',
    'text-node-assistant-v0.9.5/TOOLKIT_BUILD_REVISION',
    'text-node-assistant-v0.9.5/linux/00-bootstrap-toolkit.sh',
    'text-node-assistant-v0.9.5/linux/00-auto-install-or-optimize.sh'
)) {
    if ($archiveEntries -notcontains $entry) { throw "Toolkit archive is missing fresh-install entry: $entry" }
}
$archiveVersion = (& tar -xOf $toolkitArchive 'text-node-assistant-v0.9.5/TOOLKIT_VERSION' | Out-String).Trim()
$archiveBuildId = (& tar -xOf $toolkitArchive 'text-node-assistant-v0.9.5/TOOLKIT_BUILD_ID' | Out-String).Trim()
$archiveRevision = (& tar -xOf $toolkitArchive 'text-node-assistant-v0.9.5/TOOLKIT_BUILD_REVISION' | Out-String).Trim()
if ($archiveVersion -ne '0.9.5' -or $archiveBuildId -ne '20260831-v095-reset-from-v090-r100' -or $archiveRevision -ne '100') {
    throw "Embedded toolkit metadata is not the exact v0.9.5 revision-100 build"
}

Write-Host "ANDROID_RESET_STATIC_OK"
