#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/runbook/text-node-assistant-v0.9.5/linux/28-topology-reconcile.sh"
STATE_LIB="$ROOT/runbook/text-node-assistant-v0.9.5/linux/lib-deployment-state.sh"
OPS="$ROOT/operations.go"
WIZARD="$ROOT/runbook/text-node-assistant-v0.9.5/linux/00-auto-install-or-optimize.sh"
NGINX="$ROOT/runbook/text-node-assistant-v0.9.5/linux/05e-cdn-xhttp-nginx.sh"
VALIDATE="$ROOT/runbook/text-node-assistant-v0.9.5/linux/05g-cdn-xhttp-validate.sh"

bash -n "$SCRIPT"
bash -n "$WIZARD"
bash -n "$NGINX"
bash -n "$VALIDATE"

grep -q 'TNA_TOPOLOGY_ROLLED_BACK=1' "$SCRIPT"
grep -q 'snapshot_path /etc/x-ui x-ui' "$SCRIPT"
grep -q 'snapshot_path /root/.config/text-node-assistant/topology.env topology.env' "$SCRIPT"
grep -q 'tna_state_commit_converged direct-reality ACTIVE_DIRECT xray-reality' "$SCRIPT"
grep -q 'tna_state_commit_converged cdn-xhttp-tls ACTIVE_CDN none' "$SCRIPT"
grep -q 'tna_state_commit_converged dual-hot-switch DUAL_INSTALLED_ACTIVE_CDN xray-reality' "$SCRIPT"
grep -q 'TNA_TOPOLOGY_ERROR=CDN_ROUTE_REMAINS' "$SCRIPT"
grep -q 'TNA_TOPOLOGY_ERROR=DIRECT_ROUTE_REMAINS' "$SCRIPT"
grep -q '^tna_state_commit_converged()' "$STATE_LIB"
grep -q 'a.reconcileTopologyPlan(c, topology)' "$OPS"
grep -q 'ORANGE_ONLY_REALITY_SKIPPED' "$WIZARD"
grep -q 'if \[ "$TOPOLOGY_MODE" = orange \]' "$WIZARD"
grep -q 'TNA_TARGET_TOPOLOGY' "$NGINX"
grep -q 'ORANGE_STATE_NOT_STAGEABLE' "$NGINX"
grep -q 'DUAL_TARGET_REQUIRES_REALITY_443' "$NGINX"
grep -q 'TNA_TARGET_TOPOLOGY' "$VALIDATE"
grep -q 'ORANGE_CLIENT_CONFIRM_STATE' "$VALIDATE"
grep -q 'tna_state_commit_converged cdn-xhttp-tls ACTIVE_CDN none clean' "$VALIDATE"
grep -q 'promoteCDNPublicOriginForTopology(c, topology.OrangeDomain' "$OPS"
grep -q 'confirmCDNRealClientForTopology(c, topology.OrangeDomain' "$OPS"

reality_step="$(grep -n '^step "REALITY 443"' "$WIZARD" | cut -d: -f1)"
orange_guard="$(grep -n '^if \[ "$TOPOLOGY_MODE" = orange \]; then' "$WIZARD" | tail -n1 | cut -d: -f1)"
shadow_prompt="$(grep -n 'Import the printed 24443' "$WIZARD" | cut -d: -f1)"
[ "$orange_guard" -gt "$reality_step" ] && [ "$shadow_prompt" -gt "$orange_guard" ] || {
  echo 'orange-only Reality guard does not enclose the 24443 workflow' >&2
  exit 1
}

if grep -q 'a.persistTopologyPlan(c, topology)' "$OPS"; then
  echo 'early topology persistence remains in deploy workflow' >&2
  exit 1
fi

TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT
export TNA_DEPLOYMENT_STATE_FILE="$TMP/deployment-state.env"
export TNA_DEPLOYMENT_LOCK_FILE="$TMP/deployment.lock"
if ! command -v flock >/dev/null 2>&1; then flock() { return 0; }; fi
. "$STATE_LIB"
tna_state_commit_converged cdn-xhttp-tls CDN_STAGED_8443 none clean
tna_state_transition CDN_STAGED_8443 WAITING_FOR_CLOUDFLARE_MANUAL_ACTION cdn-xhttp-tls none clean
tna_state_transition WAITING_FOR_CLOUDFLARE_MANUAL_ACTION SWITCH_TO_CDN_STAGED_8443 cdn-xhttp-tls none clean
tna_state_commit_converged cdn-xhttp-tls ACTIVE_CDN none clean
grep -q '^DEPLOYMENT_MODE=cdn-xhttp-tls$' "$TNA_DEPLOYMENT_STATE_FILE"
grep -q '^ACTIVE_MODE=ACTIVE_CDN$' "$TNA_DEPLOYMENT_STATE_FILE"
grep -q '^PORT_443_OWNER=none$' "$TNA_DEPLOYMENT_STATE_FILE"

echo TOPOLOGY_RECONCILE_STATIC_TEST_OK
