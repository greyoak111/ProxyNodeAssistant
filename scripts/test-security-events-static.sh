#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BASELINE="$ROOT/runbook/proxy-runbook-v0.9.5/linux/24-security-baseline.sh"
EVENTS="$ROOT/runbook/proxy-runbook-v0.9.5/linux/25-security-events.sh"
NGINX="$ROOT/runbook/proxy-runbook-v0.9.5/linux/05e-cdn-xhttp-nginx.sh"
DIAG="$ROOT/runbook/proxy-runbook-v0.9.5/linux/16-auto-diagnose.sh"
DISMANTLE="$ROOT/runbook/proxy-runbook-v0.9.5/linux/22-dismantle-managed-node.sh"

for file in "$BASELINE" "$EVENTS" "$NGINX" "$DIAG" "$DISMANTLE"; do
  bash -n "$file"
done

grep -q 'PNA_MANAGED_FAIL2BAN_SSHD_V095' "$BASELINE"
grep -q 'fail2ban-client -t' "$BASELINE"
grep -q 'fail2ban-client status sshd' "$BASELINE"
grep -q 'UNMANAGED_JAIL_CONFLICT' "$BASELINE"
grep -q 'maxretry = 5' "$BASELINE"
grep -q 'findtime = 10m' "$BASELINE"
grep -q 'bantime = 1h' "$BASELINE"
grep -q -- '--limit)' "$EVENTS"
grep -q '\-le 1000' "$EVENTS"
grep -q -- '-n 5000' "$EVENTS"
grep -q '__PNA_SECURITY_V1_BEGIN__' "$EVENTS"
grep -q '__PNA_SECURITY_V1_END__' "$EVENTS"
grep -q 'source_state .* PARTIAL' "$EVENTS"
grep -q 'PNA-REALITY' "$BASELINE"
grep -q 'RAW_SECURITY_EVENT_LOGS_EXCLUDED=1' "$ROOT/runbook/proxy-runbook-v0.9.5/linux/01-safe-backup.sh"
grep -q '24-security-baseline.sh.*--remove' "$DISMANTLE"
grep -q 'FAIL2BAN_SSHD_JAIL_ACTIVE' "$DIAG"

format_line="$(grep 'log_format pna_security' "$NGINX")"
for forbidden in '\$request_uri' '\$args' '\$http_cookie' '\$http_authorization' '\$http_referer' '\$http_user_agent'; do
  if grep -q "$forbidden" <<<"$format_line"; then
    echo "unsafe field in managed security log format: $forbidden" >&2
    exit 1
  fi
done
grep -Fq 'route_class=\$pna_route_class' <<<"$format_line"
grep -Fq 'client_ip=\$remote_addr' <<<"$format_line"
grep -Fq 'edge_ip=\$realip_remote_addr' <<<"$format_line"

echo SECURITY_EVENTS_STATIC_TEST_OK
