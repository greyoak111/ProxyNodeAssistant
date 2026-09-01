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

@(
    # Both aliases are intentionally recognized so v0.9.x device records can
    # be retired without touching unrelated authorized-key entries.
    'text-node-assistant-device|proxy-node-assistant-device',
    'test("^(tna|pna)-device:")',
    '# TNA_MANAGED_COPYPARTY_V095',
    '# TNA_MANAGED_COPYPARTY_SYSTEMD_V095',
    '# TNA_MANAGED_COPYPARTY_NGINX_V095',
    'TNA_V095_RETIREMENT_UNMANAGED_PRESERVED=',
    'NGINX_OWNED=',
    'CANDIDATE_OWNED=',
    'DRIVE_DATA_PRESERVED=1',
    'chmod 0600 "$ARCHIVE_PATH"',
    'XUI_UNMANAGED_CLIENT_READBACK_MISMATCH',
    'cmp -s -- "$path" "$WORK/auth-original/$index"',
    'XUI_FINAL_READBACK_INVALID',
    'PNA_XUI_TOKEN_CACHE_FILE="$WORK/xui-helper/XUI_API_TOKEN"',
    '--apply|--status'
) | ForEach-Object { Assert-Contains $_ }

@(
    'rm -rf -- /etc/proxy-node-assistant',
    'rm -rf -- "$STATE_DIR"',
    'rm -rf -- /etc/x-ui',
    'rm -rf -- /usr/local/x-ui',
    'rm -rf -- "$NEW_DATA_ROOT"',
    'rm -rf -- "$LEGACY_DATA_ROOT"',
    'rm -f -- "$path"'
) | ForEach-Object { Assert-NotContains $_ }

Write-Host 'feature-retirement static guards: PASS'
