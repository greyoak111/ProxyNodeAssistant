#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NGINX="$ROOT/runbook/proxy-runbook-v0.9.5/linux/05e-cdn-xhttp-nginx.sh"
LOCK="$ROOT/runbook/proxy-runbook-v0.9.5/linux/05f-cloudflare-origin-lock.sh"
VALIDATE="$ROOT/runbook/proxy-runbook-v0.9.5/linux/05g-cdn-xhttp-validate.sh"
STATE="$ROOT/runbook/proxy-runbook-v0.9.5/linux/lib-deployment-state.sh"

bash -n "$NGINX"
bash -n "$LOCK"
bash -n "$VALIDATE"
bash -n "$STATE"

grep -q "printf 'listen %s:8443" "$NGINX"
grep -q 'listen 127.0.0.2:8443' "$NGINX"
grep -q 'X-PNA-Managed-Origin' "$NGINX"
grep -q 'PNA-CF-XHTTP-V095-ALLOW' "$LOCK"
grep -q 'ufw --force prepend deny' "$LOCK"
grep -q 'ufw --force prepend allow' "$LOCK"
grep -q "awk 'NF {count++} END {print count+0}'" "$LOCK"
if grep -q 'wc -l <.*ips-v' "$LOCK"; then
  echo 'Cloudflare CIDR verification must not undercount a final non-newline record' >&2
  exit 1
fi
if grep -q 'ufw --force insert 1' "$LOCK"; then
  echo 'The Cloudflare origin lock must not use the UFW 0.36.1-incompatible IPv6 insert form' >&2
  exit 1
fi
grep -q 'DENY_OTHER_SOURCES_TCP=8443' "$LOCK"
grep -q 'KEEP_REALITY_PUBLIC_TCP=443' "$LOCK"
grep -q 'REALITY_443_POLICY=UNCHANGED' "$LOCK"
grep -q 'ORIGIN_RULE_443_TO_8443=PASS' "$VALIDATE"
grep -q 'REAL_DEVICE_BROWSE=REQUIRED' "$VALIDATE"
grep -q -- '--rollback-public' "$VALIDATE"

if grep -Eqi 'api[_ -]?token|global api key|authorization:[[:space:]]*bearer' "$NGINX" "$LOCK" "$VALIDATE"; then
  echo 'Cloudflare credential handling leaked into the manual-only CDN path' >&2
  exit 1
fi

TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT
export PNA_DEPLOYMENT_STATE_FILE="$TMP/deployment-state.env"
export PNA_DEPLOYMENT_LOCK_FILE="$TMP/deployment.lock"
if ! command -v flock >/dev/null 2>&1; then flock() { return 0; }; fi
. "$STATE"
pna_state_init_direct_if_missing
pna_state_transition ACTIVE_DIRECT CDN_STAGED_8443 cdn-xhttp-tls xray-reality previously-exposed
pna_state_transition CDN_STAGED_8443 WAITING_FOR_CLOUDFLARE_MANUAL_ACTION cdn-xhttp-tls xray-reality previously-exposed
pna_state_transition WAITING_FOR_CLOUDFLARE_MANUAL_ACTION SWITCH_TO_CDN_STAGED_8443 dual-hot-switch xray-reality previously-exposed
pna_state_transition SWITCH_TO_CDN_STAGED_8443 SWITCH_TO_CDN_PORT_443_COMMITTING dual-hot-switch xray-reality previously-exposed
pna_state_transition SWITCH_TO_CDN_PORT_443_COMMITTING DUAL_INSTALLED_ACTIVE_CDN dual-hot-switch xray-reality previously-exposed
pna_state_transition DUAL_INSTALLED_ACTIVE_CDN SWITCH_TO_DIRECT_STAGED_24443 dual-hot-switch xray-reality previously-exposed
pna_state_transition SWITCH_TO_DIRECT_STAGED_24443 WAITING_FOR_CLOUDFLARE_MANUAL_ACTION dual-hot-switch xray-reality previously-exposed
pna_state_transition WAITING_FOR_CLOUDFLARE_MANUAL_ACTION DUAL_INSTALLED_ACTIVE_DIRECT dual-hot-switch xray-reality previously-exposed
pna_state_transition DUAL_INSTALLED_ACTIVE_DIRECT ACTIVE_DIRECT direct-reality xray-reality previously-exposed
grep -q '^ACTIVE_MODE=ACTIVE_DIRECT$' "$PNA_DEPLOYMENT_STATE_FILE"
grep -q '^PORT_443_OWNER=xray-reality$' "$PNA_DEPLOYMENT_STATE_FILE"

echo 'CDN_XHTTP_PRODUCTION_STATIC_TEST_OK'
