$ErrorActionPreference = 'Stop'

$repo = Split-Path -Parent $PSScriptRoot
$scriptPath = Join-Path $repo 'runbook/proxy-node-assistant-v1.0.0/linux/00-auto-install-or-optimize.sh'
if (-not (Test-Path -LiteralPath $scriptPath -PathType Leaf)) {
    throw "missing core installer: $scriptPath"
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

Require-Literal 'case "$ROUTE_MODE" in keep|gray|orange|dual)' 'route modes must be explicitly validated'
Require-Literal 'if [ -n "${TNA_ROUTE_MODE+x}" ]; then' 'an omitted route must be distinguishable from an explicitly empty route'
Require-Literal 'case "$PERFORMANCE_MODE" in preserve|auto|low|standard|high)' 'explicit performance modes must be validated without exposing the internal legacy sentinel'
Require-Literal 'case "$WARP_MODE" in preserve|ensure-on)' 'explicit WARP modes must be validated without exposing the internal legacy sentinel'
Require-Literal 'PERFORMANCE_MODE_EXPLICIT=1' 'omitted performance mode must remain distinguishable from an explicit value'
Require-Literal 'WARP_MODE_EXPLICIT=1' 'omitted WARP mode must remain distinguishable from an explicit value'
Reject-Literal 'case "$PERFORMANCE_MODE" in legacy|' 'legacy must not be accepted as an explicit client performance value'
Reject-Literal 'case "$WARP_MODE" in legacy|' 'legacy must not be accepted as an explicit client WARP value'
Require-Literal 'unknown TNA_ROUTE_MODE=' 'an unknown explicit route must fail closed'
Require-Literal 'unknown TNA_PERFORMANCE_MODE=' 'an unknown explicit performance mode must fail closed'
Require-Literal 'unknown TNA_WARP_MODE=' 'an unknown explicit WARP mode must fail closed'
Require-Literal 'unknown TNA_PLAN_CONFIRMED=' 'an unknown plan-confirmation value must fail closed'

Require-Literal 'COVER_TEMPLATE_CHOICE="${TNA_COVER_TEMPLATE:-${PROXY_RUNBOOK_COVER_TEMPLATE:-auto}}"' 'the reviewed cover choice must prefer the reset client variable'
Require-Literal 'if [ "$PLAN_CONFIRMED" = 1 ]; then' 'the client-confirmed plan must have a narrowly scoped branch'
Require-Literal 'INSTALL_PLAN_ALREADY_CONFIRMED_BY_CLIENT' 'the skipped duplicate confirmation must be explicit in logs'
Require-Literal 'yesq "Continue using this exact install plan?" || exit 0' 'standalone/legacy runs must retain plan confirmation'
Reject-Literal 'AUTO_DEFAULTS="$PLAN_CONFIRMED"' 'plan confirmation must not answer unrelated safety prompts'
Reject-Literal 'PROXY_RUNBOOK_ASSUME_DEFAULTS="$PLAN_CONFIRMED"' 'plan confirmation must not answer unrelated safety prompts'

Require-Literal '[ "$REALITY_PRODUCTION_PORT" = 443 ]' 'production Reality port must use the coordinated preset'
Require-Literal '[ "$REALITY_SHADOW_PORT" = 24443 ]' 'shadow Reality port must use the coordinated preset'
Require-Literal '[ "$CDN_ORIGIN_PORT" = 8443 ]' 'CDN origin port must use the coordinated preset'
Require-Literal '[ "$WARP_LOOPBACK_PORT" = 40000 ]' 'WARP loopback port must use the coordinated preset'
Require-Literal '${TNA_REALITY_PORT:-443}' 'the client production-port variable must feed the coordinated preset'
Require-Literal '${TNA_WARP_PORT:-40000}' 'the client WARP-port variable must feed the coordinated preset'

Require-Literal 'AUTO_INPUT="${TNA_AUTO_INPUT:-${PROXY_RUNBOOK_AUTO_INPUT:-}}"' 'the randomized auto-input path must be consumed'
Require-Literal 'GRAY_DOMAIN_B64=' 'gray hostname must be supported by the input protocol'
Require-Literal 'GRAY_EMAIL_B64=' 'gray email must be supported by the input protocol'
Require-Literal 'ORANGE_DOMAIN_B64=' 'orange hostname must be supported by the input protocol'
Require-Literal 'ORANGE_EMAIL_B64=' 'orange email must be supported by the input protocol'
Require-Literal 'cleanup_auto_input' 'the current-run input file must be cleaned'
Require-Literal 'one-run file immediately; the EXIT trap remains as the failure fallback' 'input secrets must be removed immediately after consumption and again on exit if parsing fails'
if (([regex]::Matches($source, '(?m)^\s*cleanup_auto_input\s*$')).Count -lt 3) {
    throw 'cleanup must run after input consumption, from the EXIT trap, and on the successful exit path'
}
Reject-Literal '/tmp/proxy-runbook-auto-input' 'the installer must not assume the old fixed input filename'

$dnsGuard = $source.IndexOf('if [ "$GRAY_ROUTE" -eq 1 ]; then' + "`n" + 'step "DNS FOR THE HUMAN-TYPED GRAY DOMAIN"', [StringComparison]::Ordinal)
$dnsEnd = $source.IndexOf('GRAY_ROUTE_SKIPPED mode=$ROUTE_MODE', [StringComparison]::Ordinal)
$realityGuard = $source.IndexOf('if [ "$GRAY_ROUTE" -eq 1 ]; then' + "`n" + 'step "REALITY ${REALITY_PRODUCTION_PORT}"', [StringComparison]::Ordinal)
$realityEnd = $source.IndexOf('REALITY_ROUTE_SKIPPED mode=$ROUTE_MODE', [StringComparison]::Ordinal)
if ($dnsGuard -lt 0 -or $dnsEnd -le $dnsGuard) {
    throw 'gray DNS/certificate/cover work is not enclosed by a gray-route guard'
}
if ($realityGuard -lt 0 -or $realityEnd -le $realityGuard) {
    throw 'Reality mutation is not enclosed by a gray-route guard'
}
$dnsBlock = $source.Substring($dnsGuard, $dnsEnd - $dnsGuard)
$realityBlock = $source.Substring($realityGuard, $realityEnd - $realityGuard)
if (-not $dnsBlock.Contains('05-cover-bootstrap.sh') -or -not $dnsBlock.Contains('05d-configure-subscription.sh')) {
    throw 'gray certificate/cover/subscription calls escaped the gray-route branch'
}
if (-not $realityBlock.Contains('04a-reality-api.sh') -or -not $realityBlock.Contains('04d-optimize-existing-reality-shadow.sh')) {
    throw 'Reality mutation calls escaped the gray-route branch'
}
if (([regex]::Matches($source, [regex]::Escape('05-cover-bootstrap.sh'))).Count -ne 1) {
    throw 'the certificate bootstrap must have exactly one guarded call site'
}
Require-Literal 'KEEP_ROUTE_SELECTED: certificate, cover route, subscription route, and Reality topology will not be changed.' 'keep-mode contract must be visible'
Require-Literal 'KEEP_ROUTE_FINAL_CHECK_SKIPPED' 'keep must not fail by validating an untouched Nginx route'
Require-Literal 'Orange/CDN convergence is intentionally handed to the post-core CDN module.' 'orange-mode handoff must be explicit'

Require-Literal 'BACKUP BEFORE EXISTING-NODE CHANGES' 'existing nodes must retain the mandatory backup stage'
Require-Literal 'bash "$ROOT/linux/01-safe-backup.sh"' 'existing-node backup must execute'
Require-Literal 'PERFORMANCE_PRESERVED_NO_CHANGES' 'performance preserve must be a zero-write branch'
Require-Literal 'bash "$ROOT/linux/20-adaptive-performance.sh" --apply "$PERFORMANCE_MODE"' 'explicit performance profiles must map to the existing managed script'
Require-Literal 'WARP_PRESERVED_NO_INSTALL_NO_ROUTE_CHANGE' 'WARP preserve must be a zero-convergence branch'
Require-Literal '[ "$WARP_MODE" = ensure-on ]' 'ensure-on must have an explicit idempotent branch'

Reject-Literal 'echo "  ACME_EMAIL=$ACME_EMAIL"' 'the full ACME email must never be printed'
Require-Literal 'GRAY_EMAIL=$(mask_email "$GRAY_EMAIL")' 'gray email must be masked in the review output'
Require-Literal 'ORANGE_EMAIL=$(mask_email "$ORANGE_EMAIL")' 'orange email must be masked in the review output'
$unsafeEmailOutput = $source -split "`n" | Where-Object {
    $_ -match '(echo|printf).*[\$](ACME_EMAIL|GRAY_EMAIL|ORANGE_EMAIL)' -and $_ -notmatch 'mask_email'
}
if ($unsafeEmailOutput) {
    throw "a full email variable can reach stdout/stderr: $($unsafeEmailOutput -join ' | ')"
}

Require-Literal 'echo "  proxy-node"' 'the final maintenance command must prefer the reset product command'
Require-Literal 'legacy compatibility command: text-node' 'the old maintenance command may remain only as an explicit compatibility hint'

Write-Host 'RESET_CORE_INSTALL_MODES_STATIC_OK'
