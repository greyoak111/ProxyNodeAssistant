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
Assert-Match $gradle 'versionCode\s*=\s*1000000' "Android versionCode is not the v1.0.0 release code"
Assert-Match $gradle 'versionName\s*=\s*"1\.0\.0"' "Android visible version is not v1.0.0"

$workflow = Read-RepoFile "android/app/src/main/java/com/proxynodeassistant/android/remote/WorkflowRunner.kt"
$protocolParsers = Read-RepoFile "android/app/src/main/java/com/proxynodeassistant/android/remote/ProtocolParsers.kt"
Assert-Match $workflow 'const val VERSION = "1\.0\.0"' "Android workflow visible version is not v1.0.0"
Assert-Match $workflow 'const val BUILD_REVISION = 106' "Android workflow revision is not 106"
Assert-Match $workflow 'const val BUILD_ID = "20260901-v100-ss2022-r106"' "Android workflow build id is not revision 106"
Assert-Match $workflow 'Ss2022PortPolicy\.FORMAL_PORT' "Android workflow does not use the formal SS2022 port policy"
Assert-Match $workflow 'Ss2022PortPolicy\.TRIAL_PORT' "Android workflow lost 30443 trial compatibility"
Assert-Match $workflow 'const val REMOTE_ROOT = "/opt/proxy-node-assistant-current"' "Android workflow does not use the current ProxyNodeAssistant remote root"
Assert-Match $workflow 'const val LEGACY_REMOTE_ROOT = "/opt/proxy-runbook-current"' "Android workflow lost the legacy remote-root migration probe"
Assert-Match $workflow 'const val TOOLKIT_ASSET = "proxy-node-assistant-toolkit-v1\.0\.0\.tgz"' "Android workflow does not reference the current embedded toolkit"
Assert-Match $workflow '!probe\.installed\s*->\s*true' "A completely fresh VPS no longer marks the embedded-toolkit upload as required"
Assert-Match $workflow 'if \(needsUpload\) \{[\s\S]*uploadToolkit\(handle\)' "The confirmed Android install plan no longer uploads the toolkit when required"
Assert-Match $workflow 'TOOLKIT_ONLY_UPDATE_REQUIRED reason=' "Android menu [1] no longer emits the bounded toolkit-only update marker"
Assert-Match $workflow 'sameVersionToolkitOnlyUpdateRequired\(probe\)' "Android menu [1] no longer recognizes same-version toolkit-only refreshes"
Assert-Match $workflow 'private suspend fun updateToolkitOnly\(' "Android menu [1] lost the bounded toolkit-only update helper"
Assert-Match $workflow 'TOOLKIT_ONLY_UPDATE_COMPLETE' "Android toolkit-only refresh no longer emits a completion marker"
Assert-Match $workflow 'probe\.buildRevision == BUILD_REVISION && probe\.buildId != BUILD_ID' "Android same-revision divergent/blank build IDs are not fail-closed"
Assert-Match $workflow 'sameVersionIncompleteRepairAllowed\(probe\)' "Android same-version repair lost its monotonic build guard"
Assert-Match $workflow 'credentialReadinessCommand\(\)' "Android install form lost the secret-free credential readiness probe"
Assert-Match $workflow 'ProtocolParsers\.credentialReadiness\(result\.stdout\)' "Android install form no longer parses the credential readiness marker"
Assert-Match $workflow 'credentialReadiness = detectCredentialReadiness\(handle\)' "Android install form does not run credential readiness before planning"
Assert-Match $workflow 'readiness = credentialReadiness' "Android credential policy prompts do not consume the readiness result"
Assert-Match $workflow 'complete handoff detected; preserve and verify remotely' "Android preserve option no longer identifies a complete handoff"
Assert-Match $workflow '/root/\.config/proxy-node-assistant' "Android readiness probe lost the current ProxyNodeAssistant credential-store path"
Assert-NoMatch $workflow 'printf[^\r\n]*(VPS_LOGIN_PASSWORD|PANEL_PASSWORD)=' "Android readiness probe may stream a secret-bearing credential value"
Assert-Match $protocolParsers 'CREDENTIAL_READINESS_BEGIN' "Android protocol parser lost the credential readiness markers"
Assert-Match $protocolParsers 'credential readiness unexpectedly contains credential data' "Android readiness parser no longer rejects secret-bearing output"
Assert-Match $workflow 'run action 1 and confirm APPLY for an in-place repair' "Android read-only actions do not explain the menu [1] repair path"
Assert-NoMatch $workflow '远端 v\$VERSION 工具包不完整，请先执行 \[13\]' "Android menu [1] still requires an unnecessary uninstall before repairing a partial toolkit"
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
Assert-Match $workflow 'proxy-node-assistant-\$kind-\$\{randomToken\(\)\}' "Android one-run credential/input files no longer use the bounded randomized namespace"
Assert-Match $workflow 'writeOneRunInput\(handle, installAutoInput\(plan\), "auto-input"\)' "Android action 1 no longer creates the randomized input with root-only mode 0600"
Assert-Match $workflow 'withContext\(NonCancellable\) \{ removeOneRunInput\(handle, path\) \}' "Android one-run input failures can leave a credential file behind"
Assert-Match $workflow 'writeOneRunInput\([\s\S]*"credential-input"\)' "Android menu [5]/[6] no longer uses a dedicated credential-input file"
Assert-Match $workflow 'PNA_CREDENTIAL_INPUT' "Android menu [5]/[6] no longer passes custom credentials through the one-run file"
# Credential rotation cleanup is deliberately cancellation-safe.  Keep the
# assertion tied to the inputPath finally block, but accept the hardened
# NonCancellable wrapper used by the Android workflow (and avoid regressing to
# a bare cleanup that cancellation could skip).
Assert-Match $workflow 'inputPath\?\.let \{ path -> withContext\(NonCancellable\) \{ removeOneRunInput\(handle, path\) \} \}' "Android menu [5]/[6] lost its cancellation-safe one-run cleanup"

# Action [19] is an allowlist mutation, so it must fail closed before showing
# the confirmation prompt. Keep status and list as separate calls: a successful
# list command must never mask a missing/inactive listener or firewall.
Assert-Match $workflow 'val status = handle\.exec\("bash \$REMOTE_ROOT/linux/23-ss2022-tcp\.sh status"' "Android action 19 lost the SS2022 status probe"
Assert-Match $workflow 'check\(status\.ok\)' "Android action 19 no longer treats a failed status command as fatal"
Assert-Match $workflow 'statusValues\["PRESENT"\] == "1" && statusValues\["ACTIVE"\] == "1" && statusValues\["LISTENER"\] == "1" && statusValues\["FIREWALL"\] == "1"' "Android action 19 no longer fails closed on missing SS2022 readiness gates"
Assert-Match $workflow 'val list = handle\.exec\("bash \$REMOTE_ROOT/linux/23-ss2022-tcp\.sh list"' "Android action 19 lost the separate SS2022 allowlist listing"
$statusIndex = $workflow.IndexOf('val status = handle.exec("bash $REMOTE_ROOT/linux/23-ss2022-tcp.sh status"')
$gateIndex = $workflow.IndexOf('statusValues["PRESENT"] == "1" && statusValues["ACTIVE"] == "1" && statusValues["LISTENER"] == "1" && statusValues["FIREWALL"] == "1"')
$listIndex = $workflow.IndexOf('val list = handle.exec("bash $REMOTE_ROOT/linux/23-ss2022-tcp.sh list"')
$promptIndex = $workflow.IndexOf('val answer = prompts.ask(', [Math]::Max($listIndex, 0))
if ($statusIndex -lt 0 -or $gateIndex -lt $statusIndex -or $listIndex -lt $gateIndex -or $promptIndex -lt $listIndex) {
    throw "Android action 19 may prompt before the SS2022 status/list fail-closed checks"
}
$toolkitOnlyPromptIndex = $workflow.IndexOf('private suspend fun updateToolkitOnly(')
$toolkitOnlyRecoveryIndex = $workflow.IndexOf('recoverInterruptedInstallTransaction(handle)', [Math]::Max($toolkitOnlyPromptIndex, 0))
$toolkitOnlyUploadIndex = $workflow.IndexOf('uploadToolkit(handle)', [Math]::Max($toolkitOnlyRecoveryIndex, 0))
$toolkitOnlyVerifyIndex = $workflow.IndexOf('val verified = probe(handle)', [Math]::Max($toolkitOnlyUploadIndex, 0))
if ($toolkitOnlyPromptIndex -lt 0 -or $toolkitOnlyRecoveryIndex -lt $toolkitOnlyPromptIndex -or $toolkitOnlyUploadIndex -lt $toolkitOnlyRecoveryIndex -or $toolkitOnlyVerifyIndex -lt $toolkitOnlyUploadIndex) {
    throw "Android toolkit-only refresh must confirm APPLY before recovery/upload/verification"
}
$toolkitOnlyBranchIndex = $workflow.IndexOf('if (toolkitOnlyUpdate)')
$fullPlanIndex = $workflow.IndexOf('val plan = collectInstallPlan(existingNode, existingSs2022Port)')
if ($toolkitOnlyBranchIndex -lt 0 -or $fullPlanIndex -lt 0 -or $toolkitOnlyBranchIndex -ge $fullPlanIndex) {
    throw "Android toolkit-only refresh must bypass the full route/credential plan"
}

$appUi = Read-RepoFile "android/app/src/main/java/com/proxynodeassistant/android/ui/AppUi.kt"
Assert-Match $appUi 'BUILD 1\.0\.0-R106 / ANDROID' "Android UI build label is not revision R106"

$appViewModel = Read-RepoFile "android/app/src/main/java/com/proxynodeassistant/android/ui/AppViewModel.kt"
# The dashboard may remain mounted while a workflow or another process writes
# recent targets/keys.  Remote forms must refresh both repositories at the
# point the dialog opens, rather than relying on the ViewModel-construction
# snapshot (which previously made users navigate/refresh to see credentials).
Assert-Match $appViewModel 'val freshTargets = container\.targets\.list\(\)' "Android remote form does not refresh recent targets before opening"
Assert-Match $appViewModel 'val freshKeys = container\.managedKeys\.list\(\)' "Android remote form does not refresh managed keys before opening"
Assert-Match $appViewModel 'selectedAction = action,[\s\S]*showConnection = true,[\s\S]*targets = freshTargets,[\s\S]*keys = freshKeys' "Android remote form does not publish refreshed target/key data"

# Opening a connection dialog restores only the latest non-secret endpoint.
# A corresponding bound key may be selected, but a missing key leaves auth
# unselected so the user must explicitly choose a method.  Password state must
# remain non-saveable.
Assert-Match $appUi 'val latestTarget = targets\.firstOrNull\(\)' "Connection dialog does not inspect the latest recent target"
Assert-Match $appUi 'rememberSaveable\(action\.code, targetIdentity\) \{ mutableStateOf\(latestTarget\?\.host\.orEmpty\(\)\) \}' "Connection dialog host is not initialized from the latest target"
Assert-Match $appUi 'rememberSaveable\(action\.code, targetIdentity\) \{ mutableStateOf\(latestTarget\?\.user \?: "root"\) \}' "Connection dialog user is not initialized from the latest target"
Assert-Match $appUi 'rememberSaveable\(action\.code, targetIdentity\) \{ mutableStateOf\(\(latestTarget\?\.port \?: 22\)\.toString\(\)\) \}' "Connection dialog port is not initialized from the latest target"
Assert-Match $appUi 'rememberSaveable\(action\.code, targetIdentity\) \{[\s\S]*mutableStateOf\(defaultAuthModeForTarget\(latestTarget, keys\)\)' "Connection dialog does not gate managed-key default on a local bound key"
Assert-Match $appUi 'internal fun defaultAuthModeForTarget\(target: NodeTarget\?, keys: List<ManagedKeyRecord>\): AuthMode\?' "Android connection auth default helper is missing"
Assert-Match $appUi 'mode != null && \(mode == AuthMode\.MANAGED_KEY \|\| password\.isNotBlank\(\)\)' "Connection dialog can launch without an explicit authentication choice"
Assert-Match $appUi 'keys\.any \{ it\.targetId == target\.id && it\.status == KeyStatus\.BOUND \}' "Recent-target cards do not check the matching bound key"
Assert-Match $appUi '已自动载入最近目标的地址' "Connection dialog does not explain latest-target auto-load"
Assert-Match $appUi 'var password by remember \{ mutableStateOf\(""\) \}' "Connection dialog password became saveable"

$desktopGui = Read-RepoFile "gui/ProxyNodeAssistant.Gui.cs"
Assert-Match $desktopGui 'private static List<string> RecentTargetsReadPaths\(\)' "Desktop history path resolver is missing"
Assert-Match $desktopGui 'IOPath\.Combine\(root, "TextNodeAssistant", "recent-targets\.tsv"\)' "Desktop history fallback does not use the legacy TextNodeAssistant path"
Assert-Match $desktopGui 'string legacy = IOPath\.Combine\(root, "TextNodeAssistant", "settings\.json"\)' "Desktop settings fallback does not use the legacy TextNodeAssistant path"
Assert-Match $desktopGui 'if \(remoteForm\) RefreshRecentTargets\(true\)' "Desktop operation form does not auto-load the latest endpoint"
Assert-Match $desktopGui 'private static bool HasManagedKey\(RecentTarget target\)' "Desktop operation form does not gate managed-key default on a local key pair"
Assert-Match $desktopGui 'connectionAuthMode\.SelectedIndex = HasManagedKey\(target\) \? 2 : 0' "Desktop target selection does not require an explicit auth method when no key exists"
Assert-Match $desktopGui 'connectionHostInput\.Text == target\.Host[\s\S]*connectionAuthMode\.SelectedIndex == 0' "History smoke does not verify automatic endpoint load and explicit auth"
Assert-Match $desktopGui 'historyUseButton\.RaiseEvent[\s\S]*connectionHostInput\.Text == target\.Host' "History smoke no longer verifies explicit Use remains idempotent"

$installer = Read-RepoFile "runbook/proxy-node-assistant-v1.0.0/linux/00-auto-install-or-optimize.sh"
$guiGuardIndex = $installer.IndexOf('PROXY_RUNBOOK_GUI_MODE')
$guiReadyIndex = $installer.IndexOf('CREDENTIAL_HANDOFF_READY=1')
$cliShowMatches = [regex]::Matches($installer, '(?m)^[ \t]*handoff_show[ \t]*$')
$cliShowIndex = if ($cliShowMatches.Count -gt 0) { $cliShowMatches[$cliShowMatches.Count - 1].Index } else { -1 }
if ($guiGuardIndex -lt 0 -or $guiReadyIndex -lt 0 -or $cliShowIndex -lt 0 -or
    $guiGuardIndex -ge $guiReadyIndex -or $guiReadyIndex -ge $cliShowIndex) {
    throw "Runbook still streams the raw credential handoff in GUI mode"
}

# Handoff/panel rendering must also work when an in-place v0.9.x upgrade has
# not yet moved 18-panel-metadata.sh to the renamed toolkit root.
Assert-Match $workflow 'private fun panelMetadataCommand\(\)' "Android panel metadata fallback helper is missing"
Assert-Match $workflow ([regex]::Escape('root=''$REMOTE_ROOT''')) "Panel metadata helper no longer probes the current root"
Assert-Match $workflow ([regex]::Escape('root=''$LEGACY_TEXT_REMOTE_ROOT''')) "Panel metadata helper lost the text-node legacy root"
Assert-Match $workflow ([regex]::Escape('root=''$LEGACY_REMOTE_ROOT''')) "Panel metadata helper lost the proxy-runbook legacy root"
$panelHelperIndex = $workflow.IndexOf('private fun panelMetadataCommand()')
$handoffPanelIndex = $workflow.IndexOf('ProtocolParsers.panel(checked(handle, panelMetadataCommand(), emit = false)')
$openPanelIndex = $workflow.IndexOf('val meta = ProtocolParsers.panel(checked(handle, panelMetadataCommand(), emit = false)')
if ($panelHelperIndex -lt 0 -or $handoffPanelIndex -lt 0 -or $openPanelIndex -lt 0) {
    throw "Android handoff/open-panel paths do not use the legacy-aware panel metadata helper"
}
# The protected handoff exporter must include every compatibility root and the
# split current-login store; a failed rotation can leave only that store.
foreach ($handoffRoot in @('text-node-assistant', 'proxy-runbook', 'proxy-node-assistant')) {
    Assert-Match $workflow ("emit_archive /root/\.config/$handoffRoot/handoff-archive") "Android handoff exporter lost the $handoffRoot archive"
    Assert-Match $workflow ("/root/\.config/$handoffRoot/HANDOFF-SECRETS\.txt") "Android handoff exporter lost the $handoffRoot handoff file"
    Assert-Match $workflow ("/root/\.config/$handoffRoot/CURRENT-LOGIN-CREDENTIALS\.env") "Android handoff exporter lost the $handoffRoot protected login store"
}

$androidBuilder = Read-RepoFile "android/build-android.ps1"
Assert-Match $androidBuilder 'proxy-node-assistant-v1\.0\.0/linux/00-bootstrap-toolkit\.sh' "Android build no longer verifies the fresh-VPS bootstrap entry"
Assert-Match $androidBuilder 'proxy-node-assistant-v1\.0\.0/linux/28-topology-reconcile\.sh' "Android build no longer verifies the explicit route reconciler"
Assert-Match $androidBuilder '20260901-v100-ss2022-r106' "Android build no longer verifies the exact toolkit build id"
Assert-Match $androidBuilder '\$archiveBuildRevision -ne "106"' "Android build no longer verifies toolkit revision 106"

$installPlan = Read-RepoFile "android/app/src/main/java/com/proxynodeassistant/android/remote/InstallPlan.kt"
foreach ($requiredPlanValue in @('TNA_ROUTE_MODE', 'TNA_PERFORMANCE_MODE', 'TNA_WARP_MODE', 'TNA_COVER_TEMPLATE', 'TNA_REALITY_PRODUCTION_PORT', 'TNA_REALITY_SHADOW_PORT', 'TNA_CDN_ORIGIN_PORT', 'TNA_WARP_LOOPBACK_PORT', 'TNA_PLAN_CONFIRMED', 'TNA_AUTO_INPUT')) {
    Assert-Match $installPlan ([regex]::Escape($requiredPlanValue)) "Android InstallPlan is missing explicit value $requiredPlanValue"
}
Assert-Match $installPlan 'FORMAL_PORT\s*=\s*32443' "Android InstallPlan formal SS2022 default is not 32443"
Assert-Match $installPlan 'TRIAL_PORT\s*=\s*30443' "Android InstallPlan lost 30443 trial compatibility"
Assert-Match $installPlan 'ss2022Port:\s*Int\s*=\s*Ss2022PortPolicy\.FORMAL_PORT' "Android InstallPlan does not default new nodes to the formal SS2022 port"

$vault = Read-RepoFile "android/app/src/main/java/com/proxynodeassistant/android/data/EncryptedVault.kt"
Assert-Match $vault 'keyAlias\s*=\s*"pna-v0\.9\.0-vault"' "Encrypted-vault alias changed; old Android secrets would become unreadable"

$signer = Read-RepoFile "android/build-signed-release.ps1"
Assert-Match $signer 'ProxyNodeAssistant\\android-signing' "Persistent Android signing directory changed"
Assert-Match $signer 'pna-release-v1\.jks' "Persistent Android keystore filename changed"
Assert-Match $signer '-alias pna-release-v1' "Persistent Android signing alias changed"
Assert-Match $signer 'ProxyNodeAssistant-v1\.0\.0-android-universal\.apk' "Signed APK artifact name is stale"

$packager = Read-RepoFile "package.ps1"
Assert-Match $packager '\$Version\s*=\s*"1\.0\.0"' "Package visible version is not v1.0.0"
Assert-Match $packager 'ProxyNodeAssistant-v\$Version-win64\.exe' "Package still expects a stale Windows executable name"
Assert-Match $packager 'proxy-node-assistant-toolkit-v\$ToolkitVersion\.tar\.gz' "Package still expects a stale toolkit archive name"
Assert-Match $packager '@\(\$preview, \$workflowPreview, \$toolkit, \$manual, \$beginnerGuide, \$notes, \$readme, \$license, \$androidManual, \$androidApk,' "Official packaging no longer requires the Android APK"
Assert-NoMatch $packager 'if \(Test-Path -LiteralPath \$androidApk' "Official packaging may silently omit the Android APK"
Assert-NoMatch $packager 'TextNodeAssistant-v|ProxyNodeAssistant-v0\.9' "Package would publish a stale product artifact name"

$androidSources = Get-ChildItem -LiteralPath (Join-Path $root "android/app/src") -File -Recurse |
    ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw } |
    Out-String
Assert-NoMatch $androidSources '(?i)TNAINV|device.?admission|DriveShell|copyparty|local.?admin|first.?controller' "Removed v1.0.0 experimental admission/drive/admin code leaked into the reset Android client"
Assert-NoMatch $androidSources 'Proxy Node Assistant|PROXY NODE ASSISTANT' "A visible legacy Android product name remains"
Assert-Match $androidSources '<string name="app_name">ProxyNodeAssistant</string>' "Android launcher label is not ProxyNodeAssistant in every locale"

$oldRunbookReference = Get-ChildItem -LiteralPath (Join-Path $root "scripts") -File -Recurse |
    ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw } |
    Out-String
Assert-NoMatch $oldRunbookReference 'runbook[/\\]proxy-runbook-v0\.9\.0' "A validation script still targets the removed v0.9.0 source directory"

$toolkitArchive = Join-Path $root "assets/proxy-node-assistant-toolkit-v1.0.0.tar.gz"
$toolkitAsset = Join-Path $root "android/app/src/main/assets/proxy-node-assistant-toolkit-v1.0.0.tgz"
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
if ($archiveEntries | Where-Object { $_ -notlike 'proxy-node-assistant-v1.0.0/*' }) {
    throw "Toolkit archive contains a stale or unexpected top-level directory"
}
foreach ($entry in @(
    'proxy-node-assistant-v1.0.0/TOOLKIT_VERSION',
    'proxy-node-assistant-v1.0.0/THIRD_PARTY_LOCK.env',
    'proxy-node-assistant-v1.0.0/TOOLKIT_BUILD_ID',
    'proxy-node-assistant-v1.0.0/TOOLKIT_BUILD_REVISION',
    'proxy-node-assistant-v1.0.0/linux/00-bootstrap-toolkit.sh',
    'proxy-node-assistant-v1.0.0/linux/00-auto-install-or-optimize.sh'
)) {
    if ($archiveEntries -notcontains $entry) { throw "Toolkit archive is missing fresh-install entry: $entry" }
}
$archiveVersion = (& tar -xOf $toolkitArchive 'proxy-node-assistant-v1.0.0/TOOLKIT_VERSION' | Out-String).Trim()
$archiveBuildId = (& tar -xOf $toolkitArchive 'proxy-node-assistant-v1.0.0/TOOLKIT_BUILD_ID' | Out-String).Trim()
$archiveRevision = (& tar -xOf $toolkitArchive 'proxy-node-assistant-v1.0.0/TOOLKIT_BUILD_REVISION' | Out-String).Trim()
if ($archiveVersion -ne '1.0.0' -or $archiveBuildId -ne '20260901-v100-ss2022-r106' -or $archiveRevision -ne '106') {
    throw "Embedded toolkit metadata is not the exact v1.0.0 revision-106 build"
}

Write-Host "ANDROID_RESET_STATIC_OK"
