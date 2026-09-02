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

# Firewall replacement must also recover from an interrupted port migration or
# a UFW/fail2ban chain copy.  The old implementation only removed an INPUT
# jump carrying the current --dport, which left duplicate PNA_SS2022 jumps and
# made `iptables -E` fail with rc=1 on the next run.
Require-Literal 'list_chains() {' 'firewall helper does not enumerate all iptables chains'
Require-Literal 'remove_target_jumps() {' 'firewall helper does not remove stale chain references by line number'
Require-Literal 'delete_chain() {' 'firewall helper has no guarded managed-chain deletion'
Require-Literal 'remove_target_jumps "$NEXT"' 'apply path does not clean stale next-generation jumps'
Require-Literal 'remove_target_jumps "$CHAIN"' 'apply path does not clean stale managed-chain jumps'
Require-Literal 'iptables -w 5 -D "$chain" "$line"' 'stale jumps are not deleted by line number'
Require-Literal '[ "$(count_target_jumps "$CHAIN")" -eq 1 ]' 'firewall verification does not reject duplicate managed jumps'
Require-Literal 'first_target="$(iptables -w 5 -L INPUT -n --line-numbers 2>/dev/null | awk ''$1 == 1 {print $2; exit}'')"' 'firewall verification does not require the managed jump at INPUT line 1'
Require-Literal 'LOCK_FILE="/run/lock/proxy-node-assistant-ss2022-firewall.lock"' 'firewall helper has no per-service concurrency lock'
Require-Literal 'flock -w 30 9' 'firewall helper does not serialize systemd apply/remove races'
Require-Literal 'iptables -w 5 -C INPUT -p tcp --dport "$PORT" -j "$CHAIN" >/dev/null 2>&1' 'firewall verification leaks iptables check output'
Reject-Literal 'remove_jump() {' 'legacy current-port-only jump cleanup is still present'

# A no-match grep is expected after the last legacy trial rule is removed. It
# must not trip `set -o pipefail` and roll back an otherwise healthy formal
# listener. The helper and unit writes are also required to be atomic so a
# systemd callback cannot observe a half-written file during an upgrade.
Require-Literal 'status_output="$(ufw status numbered 2>/dev/null)"' 'trial-rule cleanup does not isolate UFW status from the no-match filter'
Require-Literal 'PNA_SS2022_TRIAL_CLEANUP_WARN=' 'trial-rule cleanup has no non-blocking warning marker'
Require-Literal 'tmp="$(mktemp "$HELPER_DIR/.ss2022-firewall.XXXXXX")"' 'firewall helper is still written directly over the live file'
Require-Literal 'mv -f -- "$tmp" "$FIREWALL_HELPER"' 'firewall helper replacement is not atomic'
Require-Literal 'tmp="$(mktemp "$(dirname "$UNIT_FILE")/.proxy-node-assistant-ss2022.service.XXXXXX")"' 'SS2022 systemd unit is still written directly over the live file'
Require-Literal 'mv -f -- "$tmp" "$UNIT_FILE"' 'SS2022 systemd unit replacement is not atomic'

# The outer install transaction must snapshot the product-namespaced SS2022
# state and service too.  Otherwise a failed later stage can claim rollback
# while leaving the listener, allowlist, helper, or protected handoff changed.
$transactionPath = Join-Path $repo 'runbook/proxy-node-assistant-v1.0.0/linux/28a-install-transaction.sh'
if (-not (Test-Path -LiteralPath $transactionPath -PathType Leaf)) {
    throw "missing install transaction helper: $transactionPath"
}
$transactionSource = (Get-Content -Raw -LiteralPath $transactionPath) -replace "`r`n", "`n"
foreach ($entry in @(
    '/etc/proxy-runbook',
    '/root/.config/proxy-runbook',
    '/usr/local/libexec/proxy-node-assistant',
    '/etc/systemd/system/proxy-node-assistant-ss2022.service',
    'proxy-node-assistant-ss2022.service'
)) {
    if (-not $transactionSource.Contains($entry)) {
        throw "install transaction does not snapshot/restore SS2022 entry: $entry"
    }
}

Write-Host 'SS2022_ALLOWLIST_STATIC_OK'
