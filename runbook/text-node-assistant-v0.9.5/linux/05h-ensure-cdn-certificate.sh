#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DOMAIN="${1:-}"
EMAIL="${2:-}"
PUBLIC_IP="${3:-}"
PREPARE_PUBLIC_ORIGIN="${4:-}"
[[ "$DOMAIN" =~ ^([A-Za-z0-9][A-Za-z0-9-]*\.)+[A-Za-z]{2,63}$ ]] || { echo 'TNA_CDN_CERT_ERROR=DOMAIN_INVALID' >&2; exit 161; }
[[ "$EMAIL" =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]] || { echo 'TNA_CDN_CERT_ERROR=EMAIL_INVALID' >&2; exit 161; }
[ "$(id -u)" -eq 0 ] || { echo 'TNA_CDN_CERT_ERROR=ROOT_REQUIRED' >&2; exit 161; }

valid_ipv4() {
  local value="$1" part
  [[ "$value" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
  IFS=. read -r -a parts <<<"$value"
  [ "${#parts[@]}" -eq 4 ] || return 1
  for part in "${parts[@]}"; do
    [ "$part" -ge 0 ] 2>/dev/null && [ "$part" -le 255 ] || return 1
  done
}

if [ "$PREPARE_PUBLIC_ORIGIN" = --prepare-public-origin ]; then
  valid_ipv4 "$PUBLIC_IP" || { echo 'TNA_CDN_CERT_ERROR=PUBLIC_IP_INVALID' >&2; exit 161; }
fi

if [ -s "/etc/letsencrypt/live/${DOMAIN}/fullchain.pem" ] && \
   openssl x509 -checkend $((14*86400)) -noout -in "/etc/letsencrypt/live/${DOMAIN}/fullchain.pem" >/dev/null 2>&1; then
  echo 'TNA_CDN_CERTIFICATE_ALREADY_VALID=1'
  exit 0
fi

install -d -m 755 /var/www/cover/.well-known/acme-challenge
probe="tna-cdn-acme-$(openssl rand -hex 16)"
probe_path="/var/www/cover/.well-known/acme-challenge/$probe"
printf '%s\n' "$probe" > "$probe_path"
chmod 0644 "$probe_path"

# A user may already have an Origin Rule that sends every request for this
# hostname to origin :8443.  The old flow attempted HTTP-01 before opening
# that port, which created a deadlock: Cloudflare reached a closed port and
# the script stopped before the protected public-origin stage.  When the GUI
# asks for --prepare-public-origin, create a short-lived *plain HTTP* listener
# on the concrete VPS address and apply the Cloudflare-CIDR-only UFW rules
# first.  It serves only the ACME challenge; it is removed by cleanup before
# the permanent TLS 8443 vhost is staged.  This keeps the rule compatible
# while never exposing a bare 8443 listener to the public Internet.
CF_LOCK="$ROOT/linux/05f-cloudflare-origin-lock.sh"
CF_STATE_DIR="/etc/text-node-assistant/cloudflare"
CF_STATE="$CF_STATE_DIR/cidr-state.env"
temporary_origin_vhost="/etc/nginx/conf.d/text-node-assistant-acme-origin-$(printf '%s' "$DOMAIN" | sha256sum | awk '{print $1}').conf"
temporary_origin_created=0
firewall_applied_here=0
domain_hash="$(printf '%s' "$DOMAIN" | sha256sum | awk '{print $1}')"
acme_vhost="/etc/nginx/conf.d/text-node-assistant-acme-${domain_hash}.conf"
acme_vhost_created=0

prepare_public_origin_for_acme() {
  local existing
  [ "$PREPARE_PUBLIC_ORIGIN" = --prepare-public-origin ] || return 0
  [ -x "$CF_LOCK" ] || { echo 'TNA_CDN_CERT_ERROR=ORIGIN_LOCK_HELPER_MISSING' >&2; return 163; }
  if ! grep -Fqx 'CLOUDFLARE_FIREWALL_APPLIED=1' "$CF_STATE" 2>/dev/null; then
    bash "$CF_LOCK" fetch >/dev/null
    bash "$CF_LOCK" apply >/dev/null
    firewall_applied_here=1
  fi
  existing="$(ss -H -lntp 2>/dev/null | awk -v address="${PUBLIC_IP}:8443" '$4 == address {print; exit}')"
  if [ -n "$existing" ] && ! grep -qF '# TNA_MANAGED_CDN_XHTTP_V095' /etc/nginx/sites-available/tna-cdn-xhttp-stage 2>/dev/null; then
    echo "TNA_CDN_CERT_ERROR=PUBLIC_8443_OWNED_BY_UNKNOWN listener=$existing" >&2
    return 163
  fi
  if [ -n "$existing" ]; then
    echo 'TNA_CDN_CERT_ERROR=PUBLIC_8443_ALREADY_LISTENING' >&2
    return 163
  fi
  cat > "$temporary_origin_vhost" <<EOF
# TNA_MANAGED_ACME_ORIGIN_HTTP_V095
server {
    listen ${PUBLIC_IP}:8443;
    server_name ${DOMAIN};
    root /var/www/cover;
    location ^~ /.well-known/acme-challenge/ {
        default_type text/plain;
        auth_basic off;
        allow all;
        add_header Cache-Control "no-store" always;
        try_files \$uri =404;
    }
    location / { return 404; }
}
EOF
  chmod 644 "$temporary_origin_vhost"
  temporary_origin_created=1
  nginx -t >/dev/null 2>&1 || { echo 'TNA_CDN_CERT_ERROR=ACME_ORIGIN_VHOST_INVALID' >&2; return 163; }
  systemctl reload nginx >/dev/null 2>&1 || { echo 'TNA_CDN_CERT_ERROR=ACME_ORIGIN_VHOST_RELOAD_FAILED' >&2; return 163; }
  for _ in $(seq 1 40); do
    ss -H -lntp 2>/dev/null | awk -v address="${PUBLIC_IP}:8443" '$4 == address {found=1} END{exit found ? 0 : 1}' && break
    sleep 0.25
  done
  ss -H -lntp 2>/dev/null | awk -v address="${PUBLIC_IP}:8443" '$4 == address {found=1} END{exit found ? 0 : 1}' || {
    echo 'TNA_CDN_CERT_ERROR=ACME_ORIGIN_LISTENER_MISSING' >&2
    return 163
  }
  echo 'TNA_CDN_ACME_ORIGIN_PREPARED=1'
  echo "TNA_CDN_ACME_ORIGIN_LISTEN=${PUBLIC_IP}:8443"
  echo 'TNA_CDN_ACME_ORIGIN_SCOPE=CLOUDFLARE_ONLY'
}

cleanup() {
  rm -f -- "$probe_path"
  if [ "$temporary_origin_created" = 1 ]; then
    rm -f -- "$temporary_origin_vhost"
    nginx -t >/dev/null 2>&1 && systemctl reload nginx >/dev/null 2>&1 || true
  fi
  if [ "$acme_vhost_created" = 1 ]; then
    rm -f -- "$acme_vhost"
    nginx -t >/dev/null 2>&1 && systemctl reload nginx >/dev/null 2>&1 || true
  fi
  if [ "$firewall_applied_here" = 1 ]; then
    bash "$CF_LOCK" remove >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

prepare_public_origin_for_acme || exit $?

# A legacy node may still have a port-80 vhost for the old gray hostname.
# Install a narrowly-scoped, temporary vhost for the hostname being certified
# so the ACME path is selected by the Host header even before the production
# CDN vhost exists. It is removed on every exit (success, failure, or signal).
if [ ! -e "$acme_vhost" ]; then
  cat > "$acme_vhost" <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${DOMAIN};
    root /var/www/cover;
    location ^~ /.well-known/acme-challenge/ {
        default_type text/plain;
        auth_basic off;
        allow all;
        add_header Cache-Control "no-store" always;
        try_files \$uri =404;
    }
}
EOF
  acme_vhost_created=1
fi
nginx -t >/dev/null 2>&1 || {
  echo 'TNA_CDN_CERT_ERROR=ACME_VHOST_INVALID' >&2
  exit 162
}
systemctl reload nginx >/dev/null 2>&1 || {
  echo 'TNA_CDN_CERT_ERROR=ACME_VHOST_RELOAD_FAILED' >&2
  exit 162
}

body=''
public_status='000'
public_location=''
public_cf_ray=''
public_origin_port=''

# Verify the exact Host-selected vhost locally before blaming the public edge.
# This catches a failed reload, a port-80 collision, or a bad document root
# without spending time or an ACME rate-limit attempt on a doomed request.
local_body=''
local_status='000'
for _ in $(seq 1 4); do
  local_headers_file="$(mktemp)"
  local_body_file="$(mktemp)"
  local_status="$(curl --noproxy '*' --silent --show-error --max-time 5 \
    --dump-header "$local_headers_file" --output "$local_body_file" --write-out '%{http_code}' \
    -H 'Cache-Control: no-cache' -H 'Pragma: no-cache' \
    --resolve "${DOMAIN}:80:127.0.0.1" \
    "http://${DOMAIN}/.well-known/acme-challenge/${probe}" || true)"
  local_body="$(cat "$local_body_file" 2>/dev/null || true)"
  rm -f -- "$local_headers_file" "$local_body_file"
  [ "$local_body" = "$probe" ] && break
  sleep 1
done
if [ "$local_body" != "$probe" ]; then
  echo 'TNA_CDN_CERT_ERROR=LOCAL_ACME_PREFLIGHT_FAILED' >&2
  echo "TNA_ACME_LOCAL_HTTP_STATUS=${local_status:-000}" >&2
  echo 'TNA_ACME_LOCAL_HTTP_HINT=nginx_reload_port80_vhost_or_document_root_failed' >&2
  exit 162
fi

for _ in $(seq 1 12); do
  headers_file="$(mktemp)"
  body_file="$(mktemp)"
  public_status="$(curl --noproxy '*' --silent --show-error --max-time 5 \
    --dump-header "$headers_file" --output "$body_file" --write-out '%{http_code}' \
    -H 'Cache-Control: no-cache' -H 'Pragma: no-cache' \
    "http://${DOMAIN}/.well-known/acme-challenge/${probe}" || true)"
  body="$(cat "$body_file" 2>/dev/null || true)"
  public_location="$(awk 'BEGIN{IGNORECASE=1} /^location:/ {sub(/^[^:]*:[[:space:]]*/, ""); gsub(/[\r\n]/, ""); print; exit}' "$headers_file" 2>/dev/null || true)"
  public_cf_ray="$(awk 'BEGIN{IGNORECASE=1} /^cf-ray:/ {sub(/^[^:]*:[[:space:]]*/, ""); gsub(/[\r\n]/, ""); print; exit}' "$headers_file" 2>/dev/null || true)"
  public_origin_port="$(awk 'BEGIN{IGNORECASE=1} /^x-tna-origin-port:/ {sub(/^[^:]*:[[:space:]]*/, ""); gsub(/[\r\n]/, ""); print; exit}' "$headers_file" 2>/dev/null || true)"
  rm -f -- "$headers_file" "$body_file"
  [ "$body" = "$probe" ] && break
  sleep 1
done
if [ "$body" != "$probe" ]; then
  # A Cloudflare Origin Rule that rewrites every request to origin :8443
  # sends the HTTP-01 request as cleartext to the TLS listener.  The managed
  # XHTTP origin deliberately answers that protocol mismatch with 400 and
  # exposes the diagnostic header below.  Surface this as a precise
  # configuration error instead of making a working orange HTTPS route look
  # broken.
  if [ "${public_status:-000}" = 400 ] && [ "${public_origin_port:-}" = 8443 ]; then
    echo 'TNA_CDN_CERT_ERROR=CLOUDFLARE_HTTP_ORIGIN_RULE_MISROUTED' >&2
  else
    echo 'TNA_CDN_CERT_ERROR=PUBLIC_ACME_PREFLIGHT_FAILED' >&2
  fi
  echo "TNA_ACME_PUBLIC_HTTP_STATUS=${public_status:-000}" >&2
  [ -n "$public_location" ] && echo "TNA_ACME_PUBLIC_HTTP_LOCATION=$public_location" >&2
  [ -n "$public_cf_ray" ] && echo "TNA_ACME_PUBLIC_CF_RAY=$public_cf_ray" >&2
  [ -n "$public_origin_port" ] && echo "TNA_ACME_PUBLIC_ORIGIN_PORT=$public_origin_port" >&2
  case "${public_status:-000}" in
    301|302|303|307|308) echo 'TNA_ACME_PUBLIC_HTTP_HINT=redirect_or_Always_Use_HTTPS_must_exclude_.well-known/acme-challenge' >&2 ;;
    401|403) echo 'TNA_ACME_PUBLIC_HTTP_HINT=Cloudflare_Access_WAF_or_rule_blocked_the_ACME_path' >&2 ;;
    404) echo 'TNA_ACME_PUBLIC_HTTP_HINT=hostname_vhost_or_ACME_path_not_served' >&2 ;;
    000|5??) echo 'TNA_ACME_PUBLIC_HTTP_HINT=port_80_or_origin_unreachable_through_CDN;_free_plan_should_not_use_an_all-request_Origin_Rule_to_8443' >&2 ;;
    *) echo 'TNA_ACME_PUBLIC_HTTP_HINT=public_response_did_not_match_the_challenge_file' >&2 ;;
  esac
  if [ "${public_status:-000}" = 400 ] && [ "${public_origin_port:-}" = 8443 ]; then
    echo 'TNA_ACME_PUBLIC_HTTP_HINT=Cloudflare_Origin_Rule_must_match_HTTPS_only;_leave_HTTP_80_to_origin_80_for_HTTP-01' >&2
  fi
  exit 162
fi

certbot certonly --webroot -w /var/www/cover -d "$DOMAIN" --agree-tos --no-eff-email \
  --email "$EMAIL" --non-interactive --keep-until-expiring
test -s "/etc/letsencrypt/live/${DOMAIN}/fullchain.pem"
test -s "/etc/letsencrypt/live/${DOMAIN}/privkey.pem"
# Keep the Cloudflare-only UFW rules for the permanent public 8443 stage.  The
# EXIT trap still removes the temporary cleartext vhost and the port-80 ACME
# vhost, but deliberately leaves the protected firewall in place after a
# successful certificate issuance.  Any later stage failure has its own
# rollback transaction.
firewall_applied_here=0
echo 'TNA_CDN_CERTIFICATE_READY=1'
