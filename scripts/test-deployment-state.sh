#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT

export PNA_DEPLOYMENT_STATE_FILE="$TMP/etc/deployment-state.env"
export PNA_DEPLOYMENT_LOCK_FILE="$TMP/run/deployment.lock"
if ! command -v flock >/dev/null 2>&1; then
  # Git Bash on Windows does not ship util-linux flock. The production script
  # still requires it; this single-process unit test supplies only lock/unlock.
  flock() { return 0; }
fi
. "$ROOT/runbook/proxy-runbook-v0.9.5/linux/lib-deployment-state.sh"

pna_state_init_direct_if_missing
state="$(pna_state_show)"
grep -q '^DEPLOYMENT_MODE=direct-reality$' <<<"$state"
grep -q '^ACTIVE_MODE=ACTIVE_DIRECT$' <<<"$state"
grep -q '^PORT_443_OWNER=xray-reality$' <<<"$state"

pna_state_transition ACTIVE_DIRECT CDN_STAGED_8443 cdn-xhttp-tls xray-reality previously-exposed
state="$(pna_state_show)"
grep -q '^ACTIVE_MODE=CDN_STAGED_8443$' <<<"$state"
grep -q '^STATE_GENERATION=2$' <<<"$state"

if pna_state_transition CDN_STAGED_8443 ACTIVE_CDN cdn-xhttp-tls nginx-cdn previously-exposed 2>/dev/null; then
  echo 'unsafe transition was accepted' >&2
  exit 1
fi
grep -q '^ACTIVE_MODE=CDN_STAGED_8443$' <<<"$(pna_state_show)"

echo 'DEPLOYMENT_STATE_TEST_OK'
