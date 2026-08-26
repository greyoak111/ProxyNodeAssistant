#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NGINX="$ROOT/runbook/text-node-assistant-v0.9.5/linux/05e-cdn-xhttp-nginx.sh"
LOCK="$ROOT/runbook/text-node-assistant-v0.9.5/linux/05f-cloudflare-origin-lock.sh"
VALIDATE="$ROOT/runbook/text-node-assistant-v0.9.5/linux/05g-cdn-xhttp-validate.sh"
STATE="$ROOT/runbook/text-node-assistant-v0.9.5/linux/lib-deployment-state.sh"
API="$ROOT/runbook/text-node-assistant-v0.9.5/linux/04f-xhttp-cdn-api.sh"
CERT="$ROOT/runbook/text-node-assistant-v0.9.5/linux/05h-ensure-cdn-certificate.sh"
GO_CDN="$ROOT/cdn_xhttp.go"

bash -n "$NGINX"
bash -n "$LOCK"
bash -n "$VALIDATE"
bash -n "$STATE"
bash -n "$API"
bash -n "$CERT"

grep -q 'sha256sum' "$CERT"
grep -q 'TNA_CDN_CERT_ERROR=PUBLIC_ACME_PREFLIGHT_FAILED' "$CERT"
grep -q 'TNA_CDN_CERT_ERROR=CLOUDFLARE_HTTP_ORIGIN_RULE_MISROUTED' "$CERT"
grep -q 'TNA_CDN_CERT_ERROR=LOCAL_ACME_PREFLIGHT_FAILED' "$CERT"
grep -q 'TNA_ACME_LOCAL_HTTP_STATUS=' "$CERT"
grep -q 'TNA_ACME_PUBLIC_HTTP_STATUS=' "$CERT"
grep -q 'TNA_ACME_PUBLIC_HTTP_HINT=' "$CERT"
grep -q 'TNA_ACME_PUBLIC_CF_RAY=' "$CERT"
grep -q 'TNA_ACME_PUBLIC_ORIGIN_PORT=' "$CERT"
grep -q 'Cloudflare_Origin_Rule_must_match_HTTPS_only' "$CERT"
grep -q 'CLOUDFLARE_HTTP_ORIGIN_RULE_MISROUTED' "$GO_CDN"
grep -q 'HTTP-01' "$GO_CDN"
grep -q 'systemctl reload nginx' "$CERT"
grep -q 'trap cleanup EXIT' "$CERT"

grep -q "printf 'listen %s:8443" "$NGINX"
grep -q 'listen 127.0.0.2:8443' "$NGINX"
grep -q 'X-TNA-Managed-Origin' "$NGINX"
grep -q 'TNA-CF-XHTTP-V095-ALLOW' "$LOCK"
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
grep -q 'KEEP_PUBLIC_TCP_443_UNCHANGED=1' "$LOCK"
grep -q 'PUBLIC_TCP_443_POLICY=UNCHANGED' "$LOCK"
grep -q 'REALITY_443_PRESENT=0' "$LOCK"
grep -q 'REALITY_443_PRESENT=1' "$LOCK"
grep -q 'ORIGIN_RULE_443_TO_8443=NOT_REQUIRED_CLOUDFLARE_STANDARD_PORT' "$VALIDATE"
grep -q 'REAL_DEVICE_BROWSE=REQUIRED' "$VALIDATE"
grep -q -- '--rollback-public' "$VALIDATE"
grep -q 'retarget_managed' "$API"
grep -q 'TNA_XHTTP_RETARGETED=1' "$API"
grep -q 'LEGACY_REMARK="pna-cdn-xhttp"' "$API"
grep -q 'sync_external_proxy' "$API"
grep -q 'sync_host_group' "$API"
grep -q 'HOST_GROUP_READBACK_FAILED' "$API"
grep -q 'forceTls:"tls"' "$API"
grep -q 'HOST_GROUP_DELETE_READBACK_FAILED' "$API"
grep -q 'externalProxy=\[' "$API"
grep -q 'port:8443' "$API"
grep -q -- '--arg domain "$domain"' "$API"
grep -q 'pna-cdn-xhttp' "$ROOT/runbook/text-node-assistant-v0.9.5/linux/16-auto-diagnose.sh"
grep -q 'pna-cdn-xhttp' "$ROOT/runbook/text-node-assistant-v0.9.5/linux/26-device-admission.sh"
if grep -q 'EXISTING_DOMAIN_MISMATCH' "$API"; then
  echo 'A managed XHTTP identity must be safely retargetable during topology switching' >&2
  exit 1
fi

if grep -Eqi 'api[_ -]?token|global api key|authorization:[[:space:]]*bearer' "$NGINX" "$LOCK" "$VALIDATE"; then
  echo 'Cloudflare credential handling leaked into the manual-only CDN path' >&2
  exit 1
fi

TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT
export TNA_DEPLOYMENT_STATE_FILE="$TMP/deployment-state.env"
export TNA_DEPLOYMENT_LOCK_FILE="$TMP/deployment.lock"
if ! command -v flock >/dev/null 2>&1; then flock() { return 0; }; fi
. "$STATE"
tna_state_init_direct_if_missing
tna_state_transition ACTIVE_DIRECT CDN_STAGED_8443 cdn-xhttp-tls xray-reality previously-exposed
tna_state_transition CDN_STAGED_8443 WAITING_FOR_CLOUDFLARE_MANUAL_ACTION cdn-xhttp-tls xray-reality previously-exposed
tna_state_transition WAITING_FOR_CLOUDFLARE_MANUAL_ACTION SWITCH_TO_CDN_STAGED_8443 dual-hot-switch xray-reality previously-exposed
tna_state_transition SWITCH_TO_CDN_STAGED_8443 SWITCH_TO_CDN_PORT_443_COMMITTING dual-hot-switch xray-reality previously-exposed
tna_state_transition SWITCH_TO_CDN_PORT_443_COMMITTING DUAL_INSTALLED_ACTIVE_CDN dual-hot-switch xray-reality previously-exposed
tna_state_transition DUAL_INSTALLED_ACTIVE_CDN SWITCH_TO_DIRECT_STAGED_24443 dual-hot-switch xray-reality previously-exposed
tna_state_transition SWITCH_TO_DIRECT_STAGED_24443 WAITING_FOR_CLOUDFLARE_MANUAL_ACTION dual-hot-switch xray-reality previously-exposed
tna_state_transition WAITING_FOR_CLOUDFLARE_MANUAL_ACTION DUAL_INSTALLED_ACTIVE_DIRECT dual-hot-switch xray-reality previously-exposed
tna_state_transition DUAL_INSTALLED_ACTIVE_DIRECT ACTIVE_DIRECT direct-reality xray-reality previously-exposed
grep -q '^ACTIVE_MODE=ACTIVE_DIRECT$' "$TNA_DEPLOYMENT_STATE_FILE"
grep -q '^PORT_443_OWNER=xray-reality$' "$TNA_DEPLOYMENT_STATE_FILE"

echo 'CDN_XHTTP_PRODUCTION_STATIC_TEST_OK'
