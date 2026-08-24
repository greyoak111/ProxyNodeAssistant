#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/linux/lib-deployment-state.sh"

CF_DIR="/etc/proxy-runbook/cloudflare"
CF_STATE="$CF_DIR/cidr-state.env"
EDGE_STATE="$CF_DIR/edge-state.env"
NGINX_SITE="/etc/nginx/sites-available/pna-cdn-xhttp-stage"

[ "$(id -u)" -eq 0 ] || { echo 'ERROR: run as root.' >&2; exit 1; }
DOMAIN="${1:-}"
PUBLIC_IP="${2:-}"
MODE="${3:---local-only}"
[[ "$DOMAIN" =~ ^([A-Za-z0-9][A-Za-z0-9-]*\.)+[A-Za-z]{2,63}$ ]] || { echo 'PNA_CDN_VALIDATE_ERROR=DOMAIN_INVALID' >&2; exit 131; }
[[ "$PUBLIC_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo 'PNA_CDN_VALIDATE_ERROR=IP_INVALID' >&2; exit 131; }

listener_exists() {
  local scope="$1"
  ss -H -lntp 2>/dev/null | awk -v scope="$scope" -v public_address="${PUBLIC_IP}:8443" '
    scope == "local" && $4 == "127.0.0.2:8443" {found=1}
    scope == "public" && $4 == public_address {found=1}
    END{exit found ? 0 : 1}'
}

verify_common() {
  local xhttp
  xhttp="$($ROOT/linux/04f-xhttp-cdn-api.sh show)" || return $?
  grep -q '^XHTTP_STATUS=READY$' <<<"$xhttp" || { echo 'PNA_CDN_VALIDATE_ERROR=XHTTP_NOT_READY' >&2; return 133; }
  grep -qF '# PNA_MANAGED_CDN_XHTTP_V095' "$NGINX_SITE" || {
    echo 'PNA_CDN_VALIDATE_ERROR=NGINX_STAGE_MISSING' >&2; return 134;
  }
  nginx -t >/dev/null
}

validate_local() {
  local stage_link current
  verify_common
  listener_exists local || { echo 'PNA_CDN_VALIDATE_ERROR=STAGE_LISTENER_MISSING' >&2; return 135; }
  curl --fail --silent --show-error --max-time 10 --resolve "${DOMAIN}:8443:127.0.0.2" "https://${DOMAIN}:8443/" >/dev/null || {
    echo 'PNA_CDN_VALIDATE_ERROR=STAGE_TLS_ROOT_FAILED' >&2; return 136;
  }
  stage_link="$($ROOT/linux/04f-xhttp-cdn-api.sh link "$DOMAIN" 8443)" || return $?
  grep -q '^XHTTP_LINK=vless://' <<<"$stage_link" || { echo 'PNA_CDN_VALIDATE_ERROR=STAGE_LINK_MISSING' >&2; return 137; }
  pna_state_init_direct_if_missing
  current="$(pna_state_env_value ACTIVE_MODE || true)"
  case "$current" in
    CDN_STAGED_8443)
      pna_state_transition CDN_STAGED_8443 WAITING_FOR_CLOUDFLARE_MANUAL_ACTION cdn-xhttp-tls xray-reality previously-exposed
      ;;
    SWITCH_TO_CDN_STAGED_8443)
      pna_state_transition SWITCH_TO_CDN_STAGED_8443 WAITING_FOR_CLOUDFLARE_MANUAL_ACTION dual-hot-switch xray-reality previously-exposed
      ;;
    WAITING_FOR_CLOUDFLARE_MANUAL_ACTION|DUAL_INSTALLED_ACTIVE_DIRECT|DUAL_INSTALLED_ACTIVE_CDN) ;;
    *) echo "PNA_CDN_VALIDATE_ERROR=STATE_${current:-MISSING}" >&2; return 138 ;;
  esac
  printf '__PNA_CDN_VALIDATE_BEGIN__\n'
  printf 'CDN_LOCAL_VALIDATION=PASS\n'
  printf 'XHTTP_LOOPBACK_ONLY=1\n'
  printf 'NGINX_STAGE_8443=PASS\n'
  printf 'STAGE_LINK_STRUCTURE=GENERATED\n'
  printf 'CLOUDFLARE_DNS_PROXY=DEFERRED\n'
  printf 'CLOUDFLARE_ORIGIN_LOCK=DEFERRED\n'
  printf 'REAL_DEVICE_BROWSE=DEFERRED\n'
  printf 'PUBLIC_ORIGIN_8443=NOT_ENABLED\n'
  printf 'NEXT_STATE=WAITING_FOR_CLOUDFLARE_MANUAL_ACTION\n'
  printf '__PNA_CDN_VALIDATE_END__\n'
}

validate_origin_ready() {
  local origin_link
  verify_common
  grep -q '^CLOUDFLARE_FIREWALL_APPLIED=1$' "$CF_STATE" 2>/dev/null || {
    echo 'PNA_CDN_VALIDATE_ERROR=CLOUDFLARE_ORIGIN_LOCK_MISSING' >&2; return 139;
  }
  listener_exists public || { echo 'PNA_CDN_VALIDATE_ERROR=PUBLIC_8443_LISTENER_MISSING' >&2; return 140; }
  curl --fail --silent --show-error --max-time 10 --resolve "${DOMAIN}:8443:127.0.0.2" "https://${DOMAIN}:8443/" >/dev/null || {
    echo 'PNA_CDN_VALIDATE_ERROR=PUBLIC_ORIGIN_LOCAL_TLS_FAILED' >&2; return 141;
  }
  origin_link="$($ROOT/linux/04f-xhttp-cdn-api.sh link "$DOMAIN" 443)" || return $?
  grep -q '^XHTTP_LINK=vless://' <<<"$origin_link" || { echo 'PNA_CDN_VALIDATE_ERROR=PRODUCTION_LINK_STRUCTURE_MISSING' >&2; return 142; }
  printf '__PNA_CDN_VALIDATE_BEGIN__\n'
  printf 'CDN_ORIGIN_VALIDATION=PASS\n'
  printf 'PUBLIC_ORIGIN_LISTEN=%s:8443\n' "$PUBLIC_IP"
  printf 'PUBLIC_ORIGIN_POLICY=CLOUDFLARE_ONLY\n'
  printf 'REALITY_PUBLIC_443=UNCHANGED\n'
  printf 'CLOUDFLARE_API_MUTATION=NONE\n'
  printf 'NEXT_STATE=WAITING_FOR_CLOUDFLARE_MANUAL_ACTION\n'
  printf '__PNA_CDN_VALIDATE_END__\n'
}

verify_cloudflare_dns() {
  python3 - "$DOMAIN" "$PUBLIC_IP" "$CF_DIR/ips-v4" "$CF_DIR/ips-v6" <<'PY'
import ipaddress, socket, sys
domain, origin, path4, path6 = sys.argv[1:]
nets = []
for path in (path4, path6):
    with open(path, encoding="ascii") as stream:
        nets.extend(ipaddress.ip_network(line.strip(), strict=True) for line in stream if line.strip())
addresses = sorted({item[4][0].split("%")[0] for item in socket.getaddrinfo(domain, 443, type=socket.SOCK_STREAM)})
if not addresses:
    raise SystemExit("PNA_CDN_VALIDATE_ERROR=DNS_EMPTY")
if origin in addresses:
    raise SystemExit("PNA_CDN_VALIDATE_ERROR=DNS_LEAKS_ORIGIN_IP")
for value in addresses:
    address = ipaddress.ip_address(value)
    if not any(address in network for network in nets if network.version == address.version):
        raise SystemExit(f"PNA_CDN_VALIDATE_ERROR=DNS_NON_CLOUDFLARE_ADDRESS_{value}")
print(f"CLOUDFLARE_DNS_ADDRESS_COUNT={len(addresses)}")
print("CLOUDFLARE_DNS_PROXY=PASS")
PY
}

validate_edge() {
  local dns_result headers body current tmp status edge_link
  validate_origin_ready >/dev/null
  dns_result="$(verify_cloudflare_dns)" || return $?
  tmp="$(mktemp -d /tmp/pna-cdn-edge.XXXXXX)"
  headers="$tmp/headers"
  body="$tmp/body"
  status="$(curl --silent --show-error --location --max-time 30 --connect-timeout 10 --proto '=https' --tlsv1.2 -D "$headers" -o "$body" -w '%{http_code}' "https://${DOMAIN}/")" || {
    rm -rf -- "$tmp"
    echo 'PNA_CDN_VALIDATE_ERROR=EDGE_HTTPS_REQUEST_FAILED' >&2
    return 143
  }
  case "$status" in 2??|3??) ;; *) rm -rf -- "$tmp"; echo "PNA_CDN_VALIDATE_ERROR=EDGE_HTTP_${status}" >&2; return 143;; esac
  grep -Eiq '^cf-ray:[[:space:]]*[^[:space:]]+' "$headers" || { rm -rf -- "$tmp"; echo 'PNA_CDN_VALIDATE_ERROR=CF_RAY_MISSING' >&2; return 144; }
  grep -Eiq '^x-pna-managed-origin:[[:space:]]*cdn-xhttp-v095[[:space:]]*$' "$headers" || { rm -rf -- "$tmp"; echo 'PNA_CDN_VALIDATE_ERROR=ORIGIN_RULE_8443_NOT_PROVEN' >&2; return 145; }
  grep -Eiq '^x-pna-origin-port:[[:space:]]*8443[[:space:]]*$' "$headers" || { rm -rf -- "$tmp"; echo 'PNA_CDN_VALIDATE_ERROR=ORIGIN_PORT_HEADER_MISSING' >&2; return 145; }
  rm -rf -- "$tmp"
  edge_link="$($ROOT/linux/04f-xhttp-cdn-api.sh link "$DOMAIN" 443)" || return $?
  grep -q '^XHTTP_LINK=vless://' <<<"$edge_link" || { echo 'PNA_CDN_VALIDATE_ERROR=PRODUCTION_LINK_MISSING' >&2; return 146; }
  install -d -m 755 "$CF_DIR"
  {
    printf 'CDN_EDGE_VALIDATED=1\n'
    printf 'CDN_EDGE_DOMAIN=%s\n' "$DOMAIN"
    printf 'CDN_ORIGIN_IPV4=%s\n' "$PUBLIC_IP"
    printf 'CDN_EDGE_PORT=443\n'
    printf 'CDN_ORIGIN_PORT=8443\n'
    printf 'CDN_REAL_CLIENT_CONFIRMED=0\n'
    printf 'CDN_EDGE_VALIDATED_AT=%s\n' "$(date -Is)"
  } | install -m 644 /dev/stdin "$EDGE_STATE"
  current="$(pna_state_env_value ACTIVE_MODE || true)"
  case "$current" in
    WAITING_FOR_CLOUDFLARE_MANUAL_ACTION)
      pna_state_transition WAITING_FOR_CLOUDFLARE_MANUAL_ACTION SWITCH_TO_CDN_STAGED_8443 dual-hot-switch xray-reality previously-exposed
      ;;
    DUAL_INSTALLED_ACTIVE_DIRECT)
      pna_state_transition DUAL_INSTALLED_ACTIVE_DIRECT SWITCH_TO_CDN_STAGED_8443 dual-hot-switch xray-reality previously-exposed
      ;;
    SWITCH_TO_CDN_STAGED_8443|DUAL_INSTALLED_ACTIVE_CDN) ;;
    *) echo "PNA_CDN_VALIDATE_ERROR=EDGE_STATE_${current:-MISSING}" >&2; return 147;;
  esac
  printf '__PNA_CDN_EDGE_BEGIN__\n'
  printf '%s\n' "$dns_result"
  printf 'CLOUDFLARE_EDGE_HTTPS=PASS\n'
  printf 'CLOUDFLARE_CF_RAY=PASS\n'
  printf 'ORIGIN_RULE_443_TO_8443=PASS\n'
  printf 'CLOUDFLARE_FULL_STRICT=USER_ATTESTED_NOT_API_READABLE\n'
  printf 'CACHE_BYPASS_XHTTP_PATH=USER_ATTESTED_NOT_API_READABLE\n'
  printf 'REALITY_PUBLIC_443=UNCHANGED\n'
  printf 'REAL_DEVICE_BROWSE=REQUIRED\n'
  printf 'NEXT_STATE=SWITCH_TO_CDN_STAGED_8443\n'
  printf '__PNA_CDN_EDGE_END__\n'
}

confirm_client() {
  local current tmp
  grep -q '^CDN_EDGE_VALIDATED=1$' "$EDGE_STATE" 2>/dev/null || { echo 'PNA_CDN_VALIDATE_ERROR=EDGE_NOT_VALIDATED' >&2; return 148; }
  grep -Fqx "CDN_EDGE_DOMAIN=${DOMAIN}" "$EDGE_STATE" || { echo 'PNA_CDN_VALIDATE_ERROR=EDGE_DOMAIN_MISMATCH' >&2; return 148; }
  ss -H -lntp 2>/dev/null | grep -E ':[4]43[[:space:]].*[x]ray' >/dev/null || { echo 'PNA_CDN_VALIDATE_ERROR=REALITY_443_NOT_PRESENT' >&2; return 149; }
  current="$(pna_state_env_value ACTIVE_MODE || true)"
  case "$current" in
    SWITCH_TO_CDN_STAGED_8443)
      pna_state_transition SWITCH_TO_CDN_STAGED_8443 SWITCH_TO_CDN_PORT_443_COMMITTING dual-hot-switch xray-reality previously-exposed
      pna_state_transition SWITCH_TO_CDN_PORT_443_COMMITTING DUAL_INSTALLED_ACTIVE_CDN dual-hot-switch xray-reality previously-exposed
      ;;
    DUAL_INSTALLED_ACTIVE_CDN) ;;
    *) echo "PNA_CDN_VALIDATE_ERROR=CLIENT_CONFIRM_STATE_${current:-MISSING}" >&2; return 149;;
  esac
  tmp="$(mktemp "$CF_DIR/.edge-state.XXXXXX")"
  awk -F= '$1 != "CDN_REAL_CLIENT_CONFIRMED" && $1 != "CDN_REAL_CLIENT_CONFIRMED_AT" {print}' "$EDGE_STATE" > "$tmp"
  printf 'CDN_REAL_CLIENT_CONFIRMED=1\nCDN_REAL_CLIENT_CONFIRMED_AT=%s\n' "$(date -Is)" >> "$tmp"
  chmod 644 "$tmp"
  mv -f -- "$tmp" "$EDGE_STATE"
  printf '__PNA_CDN_EDGE_BEGIN__\nCDN_REAL_CLIENT_CONFIRMED=1\nACTIVE_MODE=DUAL_INSTALLED_ACTIVE_CDN\nREALITY_PUBLIC_443=UNCHANGED\n__PNA_CDN_EDGE_END__\n'
}

rollback_public() {
  local current
  "$ROOT/linux/05e-cdn-xhttp-nginx.sh" stage-local "$DOMAIN" "$PUBLIC_IP" >/dev/null
  "$ROOT/linux/05f-cloudflare-origin-lock.sh" remove >/dev/null
  rm -f -- "$EDGE_STATE"
  current="$(pna_state_env_value ACTIVE_MODE || true)"
  case "$current" in
    ACTIVE_DIRECT) pna_state_transition ACTIVE_DIRECT DUAL_INSTALLED_ACTIVE_DIRECT dual-hot-switch xray-reality previously-exposed ;;
    CDN_STAGED_8443)
      pna_state_transition CDN_STAGED_8443 WAITING_FOR_CLOUDFLARE_MANUAL_ACTION cdn-xhttp-tls xray-reality previously-exposed
      pna_state_transition WAITING_FOR_CLOUDFLARE_MANUAL_ACTION DUAL_INSTALLED_ACTIVE_DIRECT dual-hot-switch xray-reality previously-exposed ;;
    WAITING_FOR_CLOUDFLARE_MANUAL_ACTION)
      pna_state_transition WAITING_FOR_CLOUDFLARE_MANUAL_ACTION DUAL_INSTALLED_ACTIVE_DIRECT dual-hot-switch xray-reality previously-exposed ;;
    SWITCH_TO_CDN_STAGED_8443)
      pna_state_transition SWITCH_TO_CDN_STAGED_8443 DUAL_INSTALLED_ACTIVE_DIRECT dual-hot-switch xray-reality previously-exposed ;;
    SWITCH_TO_CDN_PORT_443_COMMITTING)
      pna_state_transition SWITCH_TO_CDN_PORT_443_COMMITTING DUAL_INSTALLED_ACTIVE_DIRECT dual-hot-switch xray-reality previously-exposed ;;
    ACTIVE_CDN)
      pna_state_transition ACTIVE_CDN DUAL_INSTALLED_ACTIVE_CDN dual-hot-switch xray-reality previously-exposed
      pna_state_transition DUAL_INSTALLED_ACTIVE_CDN SWITCH_TO_DIRECT_STAGED_24443 dual-hot-switch xray-reality previously-exposed
      pna_state_transition SWITCH_TO_DIRECT_STAGED_24443 WAITING_FOR_CLOUDFLARE_MANUAL_ACTION dual-hot-switch xray-reality previously-exposed
      pna_state_transition WAITING_FOR_CLOUDFLARE_MANUAL_ACTION DUAL_INSTALLED_ACTIVE_DIRECT dual-hot-switch xray-reality previously-exposed ;;
    DUAL_INSTALLED_ACTIVE_CDN)
      pna_state_transition DUAL_INSTALLED_ACTIVE_CDN SWITCH_TO_DIRECT_STAGED_24443 dual-hot-switch xray-reality previously-exposed
      pna_state_transition SWITCH_TO_DIRECT_STAGED_24443 WAITING_FOR_CLOUDFLARE_MANUAL_ACTION dual-hot-switch xray-reality previously-exposed
      pna_state_transition WAITING_FOR_CLOUDFLARE_MANUAL_ACTION DUAL_INSTALLED_ACTIVE_DIRECT dual-hot-switch xray-reality previously-exposed ;;
    SWITCH_TO_DIRECT_STAGED_24443)
      pna_state_transition SWITCH_TO_DIRECT_STAGED_24443 WAITING_FOR_CLOUDFLARE_MANUAL_ACTION dual-hot-switch xray-reality previously-exposed
      pna_state_transition WAITING_FOR_CLOUDFLARE_MANUAL_ACTION DUAL_INSTALLED_ACTIVE_DIRECT dual-hot-switch xray-reality previously-exposed ;;
    SWITCH_TO_DIRECT_PORT_443_COMMITTING)
      pna_state_transition SWITCH_TO_DIRECT_PORT_443_COMMITTING DUAL_INSTALLED_ACTIVE_DIRECT dual-hot-switch xray-reality previously-exposed ;;
    DUAL_INSTALLED_ACTIVE_DIRECT) ;;
    *) echo "PNA_CDN_ROLLBACK_ERROR=STATE_${current:-MISSING}" >&2; return 150;;
  esac
  printf '__PNA_CDN_EDGE_BEGIN__\nCDN_PUBLIC_ORIGIN_ROLLED_BACK=1\nCLOUDFLARE_FIREWALL_APPLIED=0\nACTIVE_MODE=DUAL_INSTALLED_ACTIVE_DIRECT\nREALITY_PUBLIC_443=UNCHANGED\n__PNA_CDN_EDGE_END__\n'
}

case "$MODE" in
  --local-only) validate_local ;;
  --origin-ready) validate_origin_ready ;;
  --edge) validate_edge ;;
  --confirm-client) confirm_client ;;
  --rollback-public) rollback_public ;;
  *) echo 'PNA_CDN_VALIDATE_ERROR=MODE_INVALID' >&2; exit 132 ;;
esac
