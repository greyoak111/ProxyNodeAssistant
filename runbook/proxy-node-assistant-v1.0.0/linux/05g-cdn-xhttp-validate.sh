#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/linux/lib-deployment-state.sh"
CF_DIR=/etc/text-node-assistant/cloudflare
CF_STATE="$CF_DIR/cidr-state.env"
EDGE_STATE="$CF_DIR/edge-state.env"

[ "$(id -u)" -eq 0 ] || { echo 'TNA_CDN_VALIDATE_ERROR=ROOT_REQUIRED' >&2; exit 130; }
valid_domain() { [[ "${1:-}" =~ ^([A-Za-z0-9][A-Za-z0-9-]*\.)+[A-Za-z]{2,63}$ ]]; }
valid_ipv4() {
  python3 - "$1" <<'PY' >/dev/null 2>&1
import ipaddress, sys
value=ipaddress.ip_address(sys.argv[1])
raise SystemExit(0 if value.version == 4 else 1)
PY
}

listener_exists() {
  local public_ip="$1"
  ss -H -lntp 2>/dev/null | awk -v address="${public_ip}:8443" '$4 == address {found=1} END{exit found ? 0 : 1}'
}

origin_ready() {
  local domain="$1" public_ip="$2" link
  valid_domain "$domain" && valid_ipv4 "$public_ip" || { echo 'TNA_CDN_VALIDATE_ERROR=IDENTITY_INVALID' >&2; return 131; }
  grep -Fqx 'CLOUDFLARE_FIREWALL_APPLIED=1' "$CF_STATE" 2>/dev/null || { echo 'TNA_CDN_VALIDATE_ERROR=ORIGIN_LOCK_MISSING' >&2; return 132; }
  listener_exists "$public_ip" || { echo 'TNA_CDN_VALIDATE_ERROR=PUBLIC_8443_LISTENER_MISSING' >&2; return 133; }
  curl --noproxy '*' --fail --silent --show-error --max-time 10 \
    --resolve "${domain}:8443:127.0.0.2" "https://${domain}:8443/" >/dev/null || {
      echo 'TNA_CDN_VALIDATE_ERROR=LOCAL_TLS_PROBE_FAILED' >&2; return 134;
    }
  link="$(bash "$ROOT/linux/04f-xhttp-cdn-api.sh" link "$domain" 8443)" || return $?
  grep -Fq "@${domain}:8443?" <<<"$link" || { echo 'TNA_CDN_VALIDATE_ERROR=LINK_ENDPOINT_INVALID' >&2; return 135; }
  grep -Fq 'security=tls' <<<"$link" || { echo 'TNA_CDN_VALIDATE_ERROR=LINK_TLS_MISSING' >&2; return 135; }
  printf '__TNA_CDN_ORIGIN_BEGIN__\nCDN_ORIGIN_READY=1\nCDN_ORIGIN_PORT=8443\nCDN_EDGE_PORT=8443\nCDN_ORIGIN_SCOPE=CLOUDFLARE_ONLY\n__TNA_CDN_ORIGIN_END__\n'
}

edge_validate() {
  local domain="$1" public_ip="$2" tmp headers status addresses target_mode owner
  valid_domain "$domain" && valid_ipv4 "$public_ip" || { echo 'TNA_CDN_VALIDATE_ERROR=IDENTITY_INVALID' >&2; return 131; }
  addresses="$(python3 - "$domain" <<'PY'
import socket, sys
print("\n".join(sorted({x[4][0].split("%")[0] for x in socket.getaddrinfo(sys.argv[1], 8443, type=socket.SOCK_STREAM)})))
PY
)" || { echo 'TNA_CDN_VALIDATE_ERROR=EDGE_DNS_FAILED' >&2; return 136; }
  [ -n "$addresses" ] || { echo 'TNA_CDN_VALIDATE_ERROR=EDGE_DNS_EMPTY' >&2; return 136; }
  ! grep -Fqx "$public_ip" <<<"$addresses" || { echo 'TNA_CDN_VALIDATE_ERROR=ORANGE_HOST_LEAKS_ORIGIN' >&2; return 136; }
  tmp="$(mktemp -d /tmp/tna-cdn-edge.XXXXXX)"; headers="$tmp/headers"
  status="$(curl --noproxy '*' --silent --show-error --location --max-time 30 --connect-timeout 10 \
    --proto '=https' --tlsv1.2 -D "$headers" -o "$tmp/body" -w '%{http_code}' "https://${domain}:8443/")" || {
      rm -rf -- "$tmp"; echo 'TNA_CDN_VALIDATE_ERROR=EDGE_HTTPS_FAILED' >&2; return 137;
    }
  case "$status" in 2??|3??) ;; *) rm -rf -- "$tmp"; echo "TNA_CDN_VALIDATE_ERROR=EDGE_HTTP_${status}" >&2; return 137;; esac
  grep -Eiq '^cf-ray:' "$headers" || { rm -rf -- "$tmp"; echo 'TNA_CDN_VALIDATE_ERROR=CLOUDFLARE_NOT_PROVEN' >&2; return 138; }
  grep -Eiq '^x-tna-managed-origin:[[:space:]]*cdn-xhttp-v095[[:space:]]*$' "$headers" || { rm -rf -- "$tmp"; echo 'TNA_CDN_VALIDATE_ERROR=MANAGED_ORIGIN_NOT_PROVEN' >&2; return 138; }
  grep -Eiq '^x-tna-origin-port:[[:space:]]*8443[[:space:]]*$' "$headers" || { rm -rf -- "$tmp"; echo 'TNA_CDN_VALIDATE_ERROR=ORIGIN_PORT_NOT_8443' >&2; return 138; }
  install -d -m 755 "$CF_DIR"
  {
    printf 'CDN_EDGE_STATE_VERSION=1\nCDN_EDGE_VALIDATED=1\n'
    printf 'CDN_EDGE_DOMAIN=%s\nCDN_EDGE_PORT=8443\nCDN_ORIGIN_PORT=8443\n' "$domain"
    printf 'CDN_EDGE_VALIDATED_AT=%s\n' "$(date -Is)"
  } | install -m 644 /dev/stdin "$EDGE_STATE"
  rm -rf -- "$tmp"
  target_mode="${TNA_TARGET_TOPOLOGY:-dual}"
  case "$target_mode" in
    orange)
      owner=none
      if ss -H -lntp 2>/dev/null | grep -qE ':[4]43[[:space:]].*[x]ray'; then owner=xray-reality; fi
      tna_state_commit_route "$([ "$owner" = none ] && printf managed-orange || printf managed-dual)" waiting-for-edge "$owner"
      ;;
    dual) tna_state_commit_route managed-dual waiting-for-edge xray-reality ;;
    *) echo 'TNA_CDN_VALIDATE_ERROR=TARGET_TOPOLOGY_INVALID' >&2; return 139;;
  esac
  printf '__TNA_CDN_EDGE_BEGIN__\nCDN_EDGE_VALIDATED=1\nCDN_EDGE_DOMAIN=%s\nCDN_EDGE_PORT=8443\nCDN_ORIGIN_PORT=8443\n__TNA_CDN_EDGE_END__\n' "$domain"
}

confirm_client() {
  local domain="$1" tmp
  valid_domain "$domain" || { echo 'TNA_CDN_VALIDATE_ERROR=DOMAIN_INVALID' >&2; return 131; }
  grep -Fqx 'CDN_EDGE_VALIDATED=1' "$EDGE_STATE" 2>/dev/null || { echo 'TNA_CDN_VALIDATE_ERROR=EDGE_NOT_VALIDATED' >&2; return 140; }
  grep -Fqx "CDN_EDGE_DOMAIN=${domain}" "$EDGE_STATE" || { echo 'TNA_CDN_VALIDATE_ERROR=EDGE_DOMAIN_MISMATCH' >&2; return 140; }
  tmp="$(mktemp "$CF_DIR/.edge-state.XXXXXX")"
  awk -F= '$1 != "CDN_CLIENT_CONFIRMED" && $1 != "CDN_CLIENT_CONFIRMED_AT" {print}' "$EDGE_STATE" > "$tmp"
  printf 'CDN_CLIENT_CONFIRMED=1\nCDN_CLIENT_CONFIRMED_AT=%s\n' "$(date -Is)" >> "$tmp"
  chmod 644 "$tmp"; mv -f -- "$tmp" "$EDGE_STATE"
  printf 'CDN_CLIENT_CONFIRMED=1\nCDN_EDGE_DOMAIN=%s\nCDN_EDGE_PORT=8443\n' "$domain"
}

reset_edge() {
  rm -f -- "$EDGE_STATE"
  echo 'TNA_CDN_EDGE_STATE_RESET=1'
}

case "${1:-}" in
  --origin-ready) [ "$#" -eq 3 ] || exit 2; origin_ready "$2" "$3" ;;
  --edge) [ "$#" -eq 3 ] || exit 2; edge_validate "$2" "$3" ;;
  --confirm-client) [ "$#" -eq 2 ] || exit 2; confirm_client "$2" ;;
  --reset) [ "$#" -eq 1 ] || exit 2; reset_edge ;;
  *) echo 'usage: 05g-cdn-xhttp-validate.sh --origin-ready DOMAIN PUBLIC_IP | --edge DOMAIN PUBLIC_IP | --confirm-client DOMAIN | --reset' >&2; exit 2;;
esac
