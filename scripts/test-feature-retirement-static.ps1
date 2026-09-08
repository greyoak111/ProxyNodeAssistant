$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$scriptPath = Join-Path $root 'runbook/proxy-node-assistant-v1.0.0/linux/00c-retire-v095-device-drive.sh'
$source = Get-Content -LiteralPath $scriptPath -Raw

function Assert-Contains([string]$Needle) {
    if (-not $source.Contains($Needle)) {
        throw "feature-retirement script is missing required guard: $Needle"
    }
}

function Assert-NotContains([string]$Needle) {
    if ($source.Contains($Needle)) {
        throw "feature-retirement script contains forbidden broad deletion: $Needle"
    }
}

function Assert-DocumentContains {
    param(
        [string]$text,
        [string]$needle,
        [string]$message
    )
    if (-not $text.Contains($needle)) {
        throw $message
    }
}

@(
    # Both aliases are intentionally recognized so v0.9.x device records can
    # be retired without touching unrelated authorized-key entries.
    'text-node-assistant-device|proxy-node-assistant-device',
    'test("^(tna|pna)-device:")',
    '# TNA_MANAGED_COPYPARTY_V095',
    '# TNA_MANAGED_COPYPARTY_SYSTEMD_V095',
    '# TNA_MANAGED_COPYPARTY_NGINX_V095',
    'TNA_V095_RETIREMENT_UNMANAGED_PRESERVED=',
    'CURRENT_STATE_DIR=/etc/proxy-runbook',
    'CURRENT_DEVICE_REGISTRY="$CURRENT_STATE_DIR/device-registry.json"',
    'CURRENT_DEVICE_REGISTRY_OWNED=',
    'CURRENT_DRIVE_STATE="$CURRENT_STATE_DIR/private-drive.env"',
    'CURRENT_DRIVE_CONFIG="$CURRENT_STATE_DIR/copyparty.conf"',
    'CURRENT_DRIVE_ESCROW="$CURRENT_STATE_DIR/drive-credential-escrow"',
    'CURRENT_DRIVE_TEMP_FILES',
    'is_owned_device_registry()',
    'is_owned_drive_state()',
    'is_owned_drive_temp()',
    'remove_current_managed_drive()',
    'CURRENT_COPYPARTY_STATE_STILL_PRESENT',
    'XUI_CONFIG_PATH=/usr/local/x-ui/bin/config.json',
    'xui_runtime_marker_count()',
    'verify_xui_runtime_config()',
    'restart_xui_after_changes()',
    'XUI_RUNTIME_STALE_MARKERS=',
    'XUI_RESTART_REQUIRED_BUT_XUI_MISSING',
    'XUI_RUNTIME_MANAGED_CLIENT_STILL_PRESENT',
    'systemctl restart x-ui',
    'XUI_RESTARTED=',
    'NGINX_OWNED=',
    'CANDIDATE_OWNED=',
    'DRIVE_DATA_PRESERVED=1',
    'chmod 0600 "$ARCHIVE_PATH"',
    'XUI_UNMANAGED_CLIENT_READBACK_MISMATCH',
    'cmp -s -- "$path" "$WORK/auth-original/$index"',
    'XUI_FINAL_READBACK_INVALID',
    'PNA_XUI_TOKEN_CACHE_FILE="$WORK/xui-helper/XUI_API_TOKEN"',
    # Global x-ui clients are a separate table from inbound clients.  The
    # retirement helper must enumerate, delete by encoded email, and verify
    # that only explicitly managed rows disappeared.
    "/panel/api/clients/list",
    "/panel/api/clients/del/",
    'collect_xui_global_clients()',
    'verify_global_snapshot_before_delete()',
    'apply_xui_global_deletions()',
    'verify_global_clients_retired()',
    'XUI_GLOBAL_CLIENTS_CHANGED_DURING_RETIREMENT',
    'XUI_GLOBAL_UNMANAGED_READBACK_MISMATCH',
    'XUI_GLOBAL_CLIENT_DELETE_FAILED',
    'XUI_GLOBAL_DEVICE_CLIENTS_ALREADY_ABSENT=',
    'all(.obj[]; type == "object")',
    'comm -23 "$current_emails" "$XUI_GLOBAL_EMAILS_FILE"',
    '--apply|--status'
) | ForEach-Object { Assert-Contains $_ }

$applyChangesCall = [regex]::Match($source, '(?m)^\s*apply_xui_changes\s*$')
$applyGlobalCall = [regex]::Match($source, '(?m)^\s*apply_xui_global_deletions\s*$')
if (-not $applyChangesCall.Success -or -not $applyGlobalCall.Success -or $applyChangesCall.Index -ge $applyGlobalCall.Index) {
    throw 'global client retirement must run after inbound client updates'
}
$restartCall = [regex]::Match($source, '(?m)^\s*restart_xui_after_changes\s*$')
$authorizedCall = [regex]::Match($source, '(?m)^\s*apply_authorized_key_changes\s*$')
if (-not $restartCall.Success -or -not $authorizedCall.Success -or $restartCall.Index -ge $authorizedCall.Index) {
    throw 'x-ui runtime reload must run before authorized-key/drive retirement'
}

# jq programs in the retirement path must be literal single-quoted filters.
# Shell interpolation of a multi-line filter was the source of the remote
# quoting regression (including the old escaped jq id expression).  Values
# such as an inbound id must cross the shell boundary with --argjson instead.
@(
    'Keep every jq program single-quoted and pass data with --arg/--argjson.',
    "jq -c '",
    'def tna_managed_client:',
    '--argjson id "$id"',
    '[.obj[] | select(.id == $id)'
) | ForEach-Object { Assert-Contains $_ }
if ($source.Contains('xui_managed_filter')) {
    throw 'feature-retirement script still interpolates a shell jq filter variable'
}
if ($source.Contains('\$id')) {
    throw 'feature-retirement script still escapes a jq variable for the shell'
}

@(
    'rm -rf -- /etc/proxy-node-assistant',
    'rm -rf -- "$STATE_DIR"',
    'rm -rf -- /etc/x-ui',
    'rm -rf -- /usr/local/x-ui',
    'rm -rf -- "$NEW_DATA_ROOT"',
    'rm -rf -- "$LEGACY_DATA_ROOT"',
    'rm -rf -- "$CURRENT_STATE_DIR"',
    'rm -rf -- /etc/proxy-runbook',
    'rm -f -- "$path"'
) | ForEach-Object { Assert-NotContains $_ }

# The reset boundary now removes local-admin/recovery/UI-gate state as well as
# the old remote admission/drive experiment. Ordinary SSH credentials and the
# complete remote handoff remain the supported login/recovery path.
$readme = Get-Content -LiteralPath (Join-Path $root 'README.md') -Encoding UTF8 -Raw
$build = Get-Content -LiteralPath (Join-Path $root 'BUILD.md') -Encoding UTF8 -Raw
$buildScript = Get-Content -LiteralPath (Join-Path $root 'build.ps1') -Encoding UTF8 -Raw
Assert-DocumentContains $readme 'SSH' 'README no longer documents an SSH login path'
Assert-DocumentContains $readme 'key' 'README no longer documents key-based login'
Assert-DocumentContains $readme 'SS2022' 'README no longer documents the complete protocol handoff'
Assert-DocumentContains $readme 'CDN/XHTTP' 'README no longer documents the CDN/XHTTP handoff'
Assert-DocumentContains $build 'SSH' 'BUILD no longer documents an SSH login path'
Assert-DocumentContains $build 'key' 'BUILD no longer documents key-based login'
Assert-DocumentContains $build 'SS2022' 'BUILD no longer documents the complete protocol handoff'
Assert-DocumentContains $buildScript 'scripts/test-feature-retirement-global-clients.sh' 'build validation no longer runs the global x-ui client fixture'
foreach ($activeText in @($readme, $build)) {
    if ($activeText -match '(?i)(remain|retained|retain).{0,80}(local-admin|recovery package|ui.?security|device.?identity)') {
        throw 'active documentation still presents retired local-admin/recovery/device-identity state as a supported feature'
    }
}

# Local migration must use the guarded config-root copier.  SSH key trees are
# deliberately still copied by the generic routine so a filename in a key
# archive cannot be mistaken for retired feature state.
$migrationPath = Join-Path $root 'migration.go'
$migration = Get-Content -LiteralPath $migrationPath -Encoding UTF8 -Raw
Assert-DocumentContains $migration 'func retiredLegacyConfigEntry' 'migration lacks the retired-feature boundary predicate'
Assert-DocumentContains $migration 'func copyLegacyConfigTree' 'migration lacks the guarded config-root copier'
Assert-DocumentContains $migration 'copyLegacyConfigTree(legacyRoot, currentRoot' 'legacy config migration bypasses the guarded copier'
Assert-DocumentContains $migration 'copyLegacyTree(legacyKeys, newKeys' 'managed SSH key migration no longer uses copy-first semantics'
Assert-DocumentContains $migration 'copyLegacyTree(legacyRevoked, newRevoked' 'revoked-key migration no longer uses copy-first semantics'
foreach ($token in @('local-admin-verifier.json', 'ui-security.json', 'device-identity.json', 'device-admission', 'private-drive', 'copyparty', 'drive-credential')) {
    Assert-DocumentContains $migration $token "migration boundary does not cover retired config token: $token"
}
if ($migration.Contains('migrateLegacyLocalAdminState') -or $migration.Contains('deviceIdentityCredentialTarget')) {
    throw 'local migration still contains a local-admin/device-identity credential migration path'
}

Write-Host 'feature-retirement static guards: PASS'
