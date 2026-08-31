#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/linux/lib-deployment-state.sh"
. "$ROOT/linux/lib-xui-api.sh"
TXN=/root/.config/text-node-assistant/cdn-route-transaction
META="$TXN/meta.env"
TOPOLOGY=/root/.config/text-node-assistant/topology.env

[ "$(id -u)" -eq 0 ] || { echo 'TNA_TOPOLOGY_ERROR=ROOT_REQUIRED' >&2; exit 141; }
valid_domain() { [[ "${1:-}" =~ ^([A-Za-z0-9][A-Za-z0-9-]*\.)+[A-Za-z]{2,63}$ ]]; }
valid_ipv4() { python3 - "$1" <<'PY' >/dev/null 2>&1
import ipaddress, sys
raise SystemExit(0 if ipaddress.ip_address(sys.argv[1]).version == 4 else 1)
PY
}
has_reality() { bash "$ROOT/linux/04a-reality-api.sh" inspect-443 >/dev/null 2>&1; }
has_xhttp() { bash "$ROOT/linux/04f-xhttp-cdn-api.sh" show >/dev/null 2>&1; }

snapshot_path() {
  local path="$1" name="$2"
  if [ -e "$path" ] || [ -L "$path" ]; then
    printf 'present\n' > "$TXN/${name}.presence"; cp -a -- "$path" "$TXN/$name"
  else printf 'absent\n' > "$TXN/${name}.presence"; fi
}
restore_path() {
  local path="$1" name="$2"
  rm -rf -- "$path"
  if grep -Fqx present "$TXN/${name}.presence" 2>/dev/null; then install -d -m 755 "$(dirname "$path")"; cp -a -- "$TXN/$name" "$path"; fi
}
begin_transaction() {
  [ ! -e "$TXN" ] || { echo 'TNA_TOPOLOGY_ERROR=PENDING_TRANSACTION_EXISTS' >&2; return 142; }
  install -d -m 700 "$TXN"
  snapshot_path /etc/x-ui x-ui
  snapshot_path /root/.config/text-node-assistant/cdn-xhttp.env cdn-xhttp.env
  snapshot_path /etc/nginx/sites-available/tna-cdn-xhttp-stage nginx-available
  snapshot_path /etc/nginx/sites-enabled/tna-cdn-xhttp-stage nginx-enabled
  snapshot_path /etc/nginx/conf.d/text-node-assistant-security-log.conf nginx-security-log
  snapshot_path /etc/text-node-assistant/cloudflare cloudflare
  snapshot_path "$TNA_DEPLOYMENT_STATE_FILE" deployment-state.env
  snapshot_path "$TOPOLOGY" topology.env
}
rollback_pending() {
  local rollback_rc=0 previous_cf_applied=0 cf_helper="$ROOT/linux/05f-cloudflare-origin-lock.sh"
  [ -d "$TXN" ] || { echo 'TNA_TOPOLOGY_ROLLBACK=NOTHING_PENDING'; return 0; }
  if grep -Fqx 'present' "$TXN/cloudflare.presence" 2>/dev/null &&
     grep -Fqx 'CLOUDFLARE_FIREWALL_APPLIED=1' "$TXN/cloudflare/cidr-state.env" 2>/dev/null; then
    previous_cf_applied=1
  fi
  set +e
  systemctl stop x-ui >/dev/null 2>&1 || rollback_rc=1

  # Files alone are not a firewall rollback.  First remove every rule carrying
  # our narrow marker, then restore the snapshotted CIDR state and recreate
  # the old managed rules only if they were active before this transaction.
  if [ -x "$cf_helper" ]; then
    bash "$cf_helper" remove >/dev/null 2>&1 || rollback_rc=1
  else
    rollback_rc=1
  fi

  restore_path /etc/x-ui x-ui || rollback_rc=1
  restore_path /root/.config/text-node-assistant/cdn-xhttp.env cdn-xhttp.env || rollback_rc=1
  restore_path /etc/nginx/sites-available/tna-cdn-xhttp-stage nginx-available || rollback_rc=1
  restore_path /etc/nginx/sites-enabled/tna-cdn-xhttp-stage nginx-enabled || rollback_rc=1
  restore_path /etc/nginx/conf.d/text-node-assistant-security-log.conf nginx-security-log || rollback_rc=1
  restore_path /etc/text-node-assistant/cloudflare cloudflare || rollback_rc=1
  restore_path "$TNA_DEPLOYMENT_STATE_FILE" deployment-state.env || rollback_rc=1
  restore_path "$TOPOLOGY" topology.env || rollback_rc=1

  if [ "$previous_cf_applied" -eq 1 ]; then
    bash "$cf_helper" apply >/dev/null 2>&1 || rollback_rc=1
  fi
  systemctl start x-ui >/dev/null 2>&1 || rollback_rc=1
  nginx -t >/dev/null 2>&1 && systemctl reload nginx >/dev/null 2>&1 || rollback_rc=1
  set -e
  if [ "$rollback_rc" -ne 0 ]; then
    echo 'TNA_TOPOLOGY_ERROR=ROLLBACK_INCOMPLETE_TRANSACTION_PRESERVED' >&2
    return 148
  fi
  rm -rf -- "$TXN"
  echo 'TNA_TOPOLOGY_ROLLED_BACK=1'
}
fail_apply() { local rc="$1"; trap - ERR INT TERM; rollback_pending >&2 || true; exit "$rc"; }

read_input() {
  local input="$1" value
  case "$input" in /root/.config/text-node-assistant/runtime-input/*.env) ;; *) echo 'TNA_TOPOLOGY_ERROR=INPUT_PATH_INVALID' >&2; return 143;; esac
  [ -f "$input" ] && [ ! -L "$input" ] && [ "$(stat -c '%u:%a' "$input")" = 0:600 ] || { echo 'TNA_TOPOLOGY_ERROR=INPUT_FILE_INVALID' >&2; return 143; }
  input_value() { awk -F= -v key="$1" '$1 == key {if (++n > 1) exit 2; print substr($0,index($0,"=")+1)} END{if(n != 1) exit 1}' "$input"; }
  [ "$(input_value TNA_CDN_ROUTE_INPUT_VERSION || true)" = 1 ] || { echo 'TNA_TOPOLOGY_ERROR=INPUT_VERSION_INVALID' >&2; return 143; }
  ROUTE_MODE="$(input_value ROUTE_MODE_B64 | base64 -d)" || return 143
  PUBLIC_IP="$(input_value PUBLIC_IPV4_B64 | base64 -d)" || return 143
  ORANGE_DOMAIN="$(input_value ORANGE_DOMAIN_B64 | base64 -d)" || return 143
  GRAY_DOMAIN="$(input_value GRAY_DOMAIN_B64 | base64 -d)" || return 143
  case "$ROUTE_MODE" in orange|dual) ;; *) echo 'TNA_TOPOLOGY_ERROR=INPUT_MODE_INVALID' >&2; return 143;; esac
  valid_ipv4 "$PUBLIC_IP" && valid_domain "$ORANGE_DOMAIN" || { echo 'TNA_TOPOLOGY_ERROR=INPUT_IDENTITY_INVALID' >&2; return 143; }
  if [ "$ROUTE_MODE" = dual ]; then valid_domain "$GRAY_DOMAIN" && [ "$GRAY_DOMAIN" != "$ORANGE_DOMAIN" ] || { echo 'TNA_TOPOLOGY_ERROR=DUAL_DOMAINS_INVALID' >&2; return 143; }; fi
}

apply_input() {
  local input="$1"
  read_input "$input"
  [ "$ROUTE_MODE" != dual ] || has_reality || { echo 'TNA_TOPOLOGY_ERROR=DUAL_REQUIRES_REALITY' >&2; return 144; }
  begin_transaction
  trap 'fail_apply $?' ERR; trap 'fail_apply 130' INT; trap 'fail_apply 143' TERM
  TNA_TARGET_TOPOLOGY="$ROUTE_MODE" bash "$ROOT/linux/04f-xhttp-cdn-api.sh" create "$ORANGE_DOMAIN"
  bash "$ROOT/linux/05h-ensure-cdn-certificate.sh" --input-file "$input"
  bash "$ROOT/linux/05f-cloudflare-origin-lock.sh" remove >/dev/null 2>&1 || true
  bash "$ROOT/linux/05f-cloudflare-origin-lock.sh" fetch
  bash "$ROOT/linux/05f-cloudflare-origin-lock.sh" apply
  TNA_TARGET_TOPOLOGY="$ROUTE_MODE" bash "$ROOT/linux/05e-cdn-xhttp-nginx.sh" stage "$ORANGE_DOMAIN" "$PUBLIC_IP"
  TNA_TARGET_TOPOLOGY="$ROUTE_MODE" bash "$ROOT/linux/05g-cdn-xhttp-validate.sh" --origin-ready "$ORANGE_DOMAIN" "$PUBLIC_IP"
  TNA_TARGET_TOPOLOGY="$ROUTE_MODE" bash "$ROOT/linux/05g-cdn-xhttp-validate.sh" --edge "$ORANGE_DOMAIN" "$PUBLIC_IP"
  {
    printf 'MODE=%s\nPUBLIC_IP=%s\nORANGE_DOMAIN=%s\nGRAY_DOMAIN=%s\n' "$ROUTE_MODE" "$PUBLIC_IP" "$ORANGE_DOMAIN" "$GRAY_DOMAIN"
  } | install -m 600 /dev/stdin "$META"
  trap - ERR INT TERM
  printf 'TNA_TOPOLOGY_STAGED=1\nTOPOLOGY_MODE=%s\nCDN_EDGE_PORT=8443\nCDN_ORIGIN_PORT=8443\n' "$ROUTE_MODE"
}

delete_managed_reality() {
  local object id response remark
  xui_api_context || { echo 'TNA_TOPOLOGY_ERROR=XUI_CONTEXT' >&2; return 145; }
  object="$(xui_api_get '/panel/api/inbounds/list' | jq -c '.obj[]? | select(.port==443)' | sed -n '1p')"
  [ -n "$object" ] || return 0
  jq -e '.protocol=="vless" and .streamSettings.security=="reality"' <<<"$object" >/dev/null || { echo 'TNA_TOPOLOGY_ERROR=PORT443_UNMANAGED' >&2; return 145; }
  remark="$(jq -r '.remark // empty' <<<"$object")"
  case "$remark" in reality-production-443|optimized-443|optimized-443-*|self-reality-443) ;; *) echo 'TNA_TOPOLOGY_ERROR=REALITY_443_NOT_TOOL_MANAGED' >&2; return 145;; esac
  id="$(jq -r '.id // empty' <<<"$object")"; case "$id" in ''|*[!0-9]*) return 145;; esac
  response="$(xui_auth_curl -X POST "${XUI_BASE}/panel/api/inbounds/del/${id}")"
  jq -e '.success==true' <<<"$response" >/dev/null || return 145
  [ -z "$(xui_api_get '/panel/api/inbounds/list' | jq -c '.obj[]? | select(.port==443)' | sed -n '1p')" ] || return 145
}

finalize() {
  local mode orange gray
  [ -r "$META" ] || { echo 'TNA_TOPOLOGY_ERROR=NO_PENDING_TRANSACTION' >&2; return 146; }
  mode="$(sed -n 's/^MODE=//p' "$META")"; orange="$(sed -n 's/^ORANGE_DOMAIN=//p' "$META")"; gray="$(sed -n 's/^GRAY_DOMAIN=//p' "$META")"
  grep -Fqx 'CDN_EDGE_VALIDATED=1' /etc/text-node-assistant/cloudflare/edge-state.env || return 146
  grep -Fqx 'CDN_CLIENT_CONFIRMED=1' /etc/text-node-assistant/cloudflare/edge-state.env || { echo 'TNA_TOPOLOGY_ERROR=CLIENT_NOT_CONFIRMED' >&2; return 146; }
  has_xhttp || return 146
  case "$mode" in
    orange) delete_managed_reality; ! has_reality || return 146; tna_state_commit_route managed-orange active none ;;
    dual) has_reality || return 146; tna_state_commit_route managed-dual active xray-reality ;;
    *) return 146;;
  esac
  install -d -m 700 "$(dirname "$TOPOLOGY")"
  { printf 'TOPOLOGY_STATE_VERSION=2\nTOPOLOGY_MODE=%s\nORANGE_DOMAIN=%s\n' "$mode" "$orange"; [ "$mode" != dual ] || printf 'GRAY_DOMAIN=%s\n' "$gray"; } | install -m 600 /dev/stdin "$TOPOLOGY"
  rm -rf -- "$TXN"
  printf 'TNA_TOPOLOGY_RECONCILED=1\nTOPOLOGY_MODE=%s\n' "$mode"
}

to_gray() {
  local gray_domain="${1:-}"
  valid_domain "$gray_domain" || { echo 'TNA_TOPOLOGY_ERROR=GRAY_DOMAIN_INVALID' >&2; return 147; }
  has_reality || { echo 'TNA_TOPOLOGY_ERROR=DIRECT_ROUTE_NOT_VERIFIED' >&2; return 147; }
  begin_transaction
  trap 'fail_apply $?' ERR; trap 'fail_apply 130' INT; trap 'fail_apply 143' TERM
  bash "$ROOT/linux/05e-cdn-xhttp-nginx.sh" disable-stage
  bash "$ROOT/linux/05f-cloudflare-origin-lock.sh" remove
  bash "$ROOT/linux/04f-xhttp-cdn-api.sh" delete
  rm -f -- /etc/text-node-assistant/cloudflare/edge-state.env
  has_reality && ! has_xhttp || return 147
  tna_state_commit_route managed-gray active xray-reality
  { printf 'TOPOLOGY_STATE_VERSION=2\nTOPOLOGY_MODE=gray\nGRAY_DOMAIN=%s\n' "$gray_domain"; } | install -m 600 /dev/stdin "$TOPOLOGY"
  rm -rf -- "$TXN"; trap - ERR INT TERM
  echo 'TNA_TOPOLOGY_RECONCILED=1'; echo 'TOPOLOGY_MODE=gray'
}

case "${1:-}" in
  --apply-input) [ "$#" -eq 2 ] || exit 2; apply_input "$2" ;;
  --finalize) [ "$#" -eq 1 ] || exit 2; finalize ;;
  --rollback-pending) [ "$#" -eq 1 ] || exit 2; rollback_pending ;;
  --to-gray) [ "$#" -eq 2 ] || exit 2; to_gray "$2" ;;
  --status) tna_state_show ;;
  *) echo 'usage: 28-topology-reconcile.sh --apply-input PATH | --finalize | --rollback-pending | --to-gray DOMAIN | --status' >&2; exit 2;;
esac
