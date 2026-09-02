$ErrorActionPreference = 'Stop'

$repo = Split-Path -Parent $PSScriptRoot
$scriptPath = Join-Path $repo 'runbook/proxy-node-assistant-v1.0.0/linux/23-ss2022-tcp.sh'
if (-not (Test-Path -LiteralPath $scriptPath -PathType Leaf)) {
    throw "missing SS2022 management script: $scriptPath"
}

$source = (Get-Content -Raw -LiteralPath $scriptPath) -replace "`r`n", "`n"

function Require-Literal([string]$needle, [string]$message) {
    if (-not $source.Contains($needle)) {
        throw "$message (missing: $needle)"
    }
}

function Reject-Literal([string]$needle, [string]$message) {
    if ($source.Contains($needle)) {
        throw "$message (found: $needle)"
    }
}

# The source validator must accept only one exact, globally routable IPv4.
Require-Literal 'if "/" in value:' 'SS2022 source validation must reject CIDR ranges'
Require-Literal 'if obj.version != 4 or not obj.is_global:' 'SS2022 source validation must reject non-global/non-IPv4 values'
Require-Literal 'print(obj.compressed)' 'SS2022 sources must be emitted in canonical form'

# Keep the small mutation primitives stable for existing clients.
Require-Literal 'allow) allow_source "${1:-}" ;;' 'allow primitive was removed'
Require-Literal 'remove) remove_source "${1:-}" ;;' 'remove primitive was removed'
Require-Literal 'list) list_sources ;;' 'list primitive was removed'
Require-Literal 'normalize_source "${1:-}"' 'allow/remove no longer validate their source argument'
Require-Literal 'if ! "$FIREWALL_HELPER" apply || ! "$FIREWALL_HELPER" verify; then' 'allow/remove no longer verify the applied firewall transaction'

# Snapshot is a single read path for clients that need both readiness and the
# current entries.  It must call status first, propagate failure, and then use
# the strict machine-readable emitter; list must never mask a failed status.
Require-Literal 'snapshot() {' 'snapshot read path is missing'
Require-Literal 'status || return $?' 'snapshot does not propagate a failed status'
Require-Literal 'list_sources_strict' 'snapshot does not use the strict allowlist emitter'
Require-Literal 'snapshot) snapshot ;;' 'snapshot is not exposed as a remote subcommand'
Require-Literal 'PNA_SS2022_ALLOWLIST_BEGIN' 'allowlist begin marker is missing'
Require-Literal 'PNA_SS2022_ALLOWLIST_END' 'allowlist end marker is missing'
Require-Literal 'printf ''SOURCE=%s\n'' "$source"' 'allowlist entries are not machine-readable SOURCE records'
Require-Literal 'die "invalid_allowlist_state"' 'snapshot does not reject malformed state entries'
Require-Literal 'die "duplicate_allowlist_state"' 'snapshot does not reject duplicate state entries'

$snapshotBody = $source.Substring($source.IndexOf('snapshot() {', [StringComparison]::Ordinal))
$snapshotEnd = $snapshotBody.IndexOf("uninstall_service() {", [StringComparison]::Ordinal)
if ($snapshotEnd -lt 0) { throw 'snapshot function boundary is not recognizable' }
$snapshotBody = $snapshotBody.Substring(0, $snapshotEnd)
$statusIndex = $snapshotBody.IndexOf('status || return $?', [StringComparison]::Ordinal)
$strictIndex = $snapshotBody.IndexOf('list_sources_strict', [StringComparison]::Ordinal)
if ($statusIndex -lt 0 -or $strictIndex -lt $statusIndex) {
    throw 'snapshot may emit the allowlist before the status gate'
}

# The strict emitter ignores blank lines, but never silently accepts a
# non-canonical address or duplicate.  This keeps output parseable even if a
# root operator hand-edits the state file.
Require-Literal '[ -f "$ALLOWLIST_FILE" ] || die "allowlist_missing"' 'snapshot does not fail closed on a missing allowlist file'
Require-Literal 'normalized="$(normalize_source "$source" 2>/dev/null || true)"' 'snapshot does not canonicalize each allowlist entry'

Write-Host 'SS2022_ALLOWLIST_STATIC_OK'
