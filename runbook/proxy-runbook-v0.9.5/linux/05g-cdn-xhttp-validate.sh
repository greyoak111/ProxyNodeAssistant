#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/linux/lib-deployment-state.sh"

[ "$(id -u)" -eq 0 ] || { echo 'ERROR: run as root.' >&2; exit 1; }
DOMAIN="${1:-}"
PUBLIC_IP="${2:-}"
MODE="${3:---local-only}"
[[ "$DOMAIN" =~ ^([A-Za-z0-9][A-Za-z0-9-]*\.)+[A-Za-z]{2,63}$ ]] || { echo 'PNA_CDN_VALIDATE_ERROR=DOMAIN_INVALID' >&2; exit 131; }
[[ "$PUBLIC_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo 'PNA_CDN_VALIDATE_ERROR=IP_INVALID' >&2; exit 131; }
[ "$MODE" = '--local-only' ] || { echo 'PNA_CDN_VALIDATE_ERROR=ORANGE_CLOUD_VALIDATION_DEFERRED' >&2; exit 132; }
STAGE_ADDRESS='127.0.0.2'

xhttp="$($ROOT/linux/04f-xhttp-cdn-api.sh show)" || exit $?
grep -q '^XHTTP_STATUS=READY$' <<<"$xhttp" || { echo 'PNA_CDN_VALIDATE_ERROR=XHTTP_NOT_READY' >&2; exit 133; }
grep -qF '# PNA_MANAGED_CDN_XHTTP_V095' /etc/nginx/sites-available/pna-cdn-xhttp-stage || {
  echo 'PNA_CDN_VALIDATE_ERROR=NGINX_STAGE_MISSING' >&2; exit 134;
}
nginx -t >/dev/null
ss -lntp 2>/dev/null | awk -v address="${STAGE_ADDRESS}:8443" '$4 == address {found=1} END{exit found ? 0 : 1}' || {
  echo 'PNA_CDN_VALIDATE_ERROR=STAGE_LISTENER_MISSING' >&2; exit 135;
}
curl --fail --silent --show-error --max-time 10 --resolve "${DOMAIN}:8443:${STAGE_ADDRESS}" "https://${DOMAIN}:8443/" >/dev/null || {
  echo 'PNA_CDN_VALIDATE_ERROR=STAGE_TLS_ROOT_FAILED' >&2; exit 136;
}
stage_link="$($ROOT/linux/04f-xhttp-cdn-api.sh link "$DOMAIN" 8443)" || exit $?
grep -q '^XHTTP_LINK=vless://' <<<"$stage_link" || { echo 'PNA_CDN_VALIDATE_ERROR=STAGE_LINK_MISSING' >&2; exit 137; }

current="$(pna_state_env_value ACTIVE_MODE || true)"
case "$current" in
  CDN_STAGED_8443)
    pna_state_transition CDN_STAGED_8443 WAITING_FOR_CLOUDFLARE_MANUAL_ACTION cdn-xhttp-tls xray-reality previously-exposed
    ;;
  SWITCH_TO_CDN_STAGED_8443)
    pna_state_transition SWITCH_TO_CDN_STAGED_8443 WAITING_FOR_CLOUDFLARE_MANUAL_ACTION dual-hot-switch xray-reality previously-exposed
    ;;
  WAITING_FOR_CLOUDFLARE_MANUAL_ACTION) ;;
  *) echo "PNA_CDN_VALIDATE_ERROR=STATE_${current:-MISSING}" >&2; exit 138 ;;
esac

printf '__PNA_CDN_VALIDATE_BEGIN__\n'
printf 'CDN_LOCAL_VALIDATION=PASS\n'
printf 'XHTTP_LOOPBACK_ONLY=1\n'
printf 'NGINX_STAGE_8443=PASS\n'
printf 'STAGE_LINK_STRUCTURE=GENERATED\n'
printf 'CLOUDFLARE_DNS_PROXY=DEFERRED\n'
printf 'CLOUDFLARE_ORIGIN_LOCK=DEFERRED\n'
printf 'REAL_DEVICE_BROWSE=DEFERRED\n'
printf 'PRODUCTION_443_PROMOTION=BLOCKED\n'
printf 'NEXT_STATE=WAITING_FOR_CLOUDFLARE_MANUAL_ACTION\n'
printf '__PNA_CDN_VALIDATE_END__\n'
