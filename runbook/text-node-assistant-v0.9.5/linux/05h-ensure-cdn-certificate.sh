#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

# Obtain the origin certificate before the permanent Cloudflare-only :8443
# listener exists.  The client and Cloudflare both use hostname:8443, so an
# Origin Rule which rewrites :443 to :8443 is neither needed nor supported.
# HTTP-01 is deliberately served only on the normal origin port 80.

INPUT_FILE=''
DOMAIN=''
EMAIL=''
PUBLIC_IP=''

[ "${1:-}" = --input-file ] && [ "$#" -eq 2 ] || {
  echo 'usage: 05h-ensure-cdn-certificate.sh --input-file ROOT_ONLY_PATH' >&2
  exit 2
}
INPUT_FILE="$2"
case "$INPUT_FILE" in
  /root/.config/text-node-assistant/runtime-input/*.env) ;;
  *) echo 'TNA_CDN_CERT_ERROR=INPUT_PATH_INVALID' >&2; exit 161 ;;
esac
[ -f "$INPUT_FILE" ] && [ ! -L "$INPUT_FILE" ] || {
  echo 'TNA_CDN_CERT_ERROR=INPUT_FILE_INVALID' >&2
  exit 161
}
[ "$(stat -c '%u:%a' "$INPUT_FILE")" = 0:600 ] || {
  echo 'TNA_CDN_CERT_ERROR=INPUT_FILE_PERMISSIONS' >&2
  exit 161
}
[ "$(id -u)" -eq 0 ] || { echo 'TNA_CDN_CERT_ERROR=ROOT_REQUIRED' >&2; exit 161; }

input_value() {
  local key="$1" value
  value="$(awk -F= -v key="$key" '$1 == key {if (++n > 1) exit 2; print substr($0, index($0,"=")+1)} END{if (n != 1) exit 1}' "$INPUT_FILE")" || return 1
  printf '%s' "$value"
}

[ "$(input_value TNA_CDN_ROUTE_INPUT_VERSION || true)" = 1 ] || {
  echo 'TNA_CDN_CERT_ERROR=INPUT_VERSION_INVALID' >&2
  exit 161
}
DOMAIN="$(input_value ORANGE_DOMAIN_B64 | base64 -d)" || {
  echo 'TNA_CDN_CERT_ERROR=DOMAIN_DECODE_FAILED' >&2
  exit 161
}
EMAIL="$(input_value ORANGE_EMAIL_B64 | base64 -d)" || {
  echo 'TNA_CDN_CERT_ERROR=EMAIL_DECODE_FAILED' >&2
  exit 161
}
PUBLIC_IP="$(input_value PUBLIC_IPV4_B64 | base64 -d)" || {
  echo 'TNA_CDN_CERT_ERROR=PUBLIC_IP_DECODE_FAILED' >&2
  exit 161
}
[[ "$DOMAIN" =~ ^([A-Za-z0-9][A-Za-z0-9-]*\.)+[A-Za-z]{2,63}$ ]] || {
  echo 'TNA_CDN_CERT_ERROR=DOMAIN_INVALID' >&2
  exit 161
}
[[ "$EMAIL" =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]] || {
  echo 'TNA_CDN_CERT_ERROR=EMAIL_INVALID' >&2
  exit 161
}
python3 - "$PUBLIC_IP" <<'PY' >/dev/null 2>&1 || {
import ipaddress
import sys
raise SystemExit(0 if ipaddress.ip_address(sys.argv[1]).version == 4 else 1)
PY
  echo 'TNA_CDN_CERT_ERROR=PUBLIC_IP_INVALID' >&2
  exit 161
}

if [ -s "/etc/letsencrypt/live/${DOMAIN}/fullchain.pem" ] && \
   [ -s "/etc/letsencrypt/live/${DOMAIN}/privkey.pem" ] && \
   openssl x509 -checkend $((14 * 86400)) -noout \
     -in "/etc/letsencrypt/live/${DOMAIN}/fullchain.pem" >/dev/null 2>&1; then
  echo 'TNA_CDN_CERTIFICATE_ALREADY_VALID=1'
  exit 0
fi

command -v nginx >/dev/null 2>&1 || { echo 'TNA_CDN_CERT_ERROR=NGINX_MISSING' >&2; exit 162; }
command -v certbot >/dev/null 2>&1 || { echo 'TNA_CDN_CERT_ERROR=CERTBOT_MISSING' >&2; exit 162; }

install -d -m 755 /var/www/cover/.well-known/acme-challenge
domain_hash="$(printf '%s' "$DOMAIN" | sha256sum | awk '{print $1}')"
acme_vhost="/etc/nginx/conf.d/text-node-assistant-acme-${domain_hash}.conf"
probe="tna-cdn-acme-$(openssl rand -hex 16)"
probe_path="/var/www/cover/.well-known/acme-challenge/${probe}"
printf '%s\n' "$probe" > "$probe_path"
chmod 0644 "$probe_path"

cleanup() {
  rm -f -- "$probe_path"
  if grep -Fqx '# TNA_MANAGED_CDN_ACME_HTTP01_V095' "$acme_vhost" 2>/dev/null; then
    rm -f -- "$acme_vhost"
    nginx -t >/dev/null 2>&1 && systemctl reload nginx >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

if [ -e "$acme_vhost" ] && ! grep -Fqx '# TNA_MANAGED_CDN_ACME_HTTP01_V095' "$acme_vhost"; then
  echo 'TNA_CDN_CERT_ERROR=ACME_VHOST_NOT_TOOL_MANAGED' >&2
  exit 162
fi
cat > "$acme_vhost" <<EOF
# TNA_MANAGED_CDN_ACME_HTTP01_V095
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
    location / { return 404; }
}
EOF
chmod 0644 "$acme_vhost"
nginx -t >/dev/null 2>&1 || { echo 'TNA_CDN_CERT_ERROR=ACME_VHOST_INVALID' >&2; exit 162; }
systemctl reload nginx >/dev/null 2>&1 || {
  echo 'TNA_CDN_CERT_ERROR=ACME_VHOST_RELOAD_FAILED' >&2
  exit 162
}

# Prove the exact Host-selected vhost locally before using a public ACME
# attempt.  This cannot be satisfied by an unrelated default server block.
local_body=''
local_status='000'
for _ in $(seq 1 4); do
  local_body_file="$(mktemp)"
  local_status="$(curl --noproxy '*' --silent --show-error --max-time 5 \
    --output "$local_body_file" --write-out '%{http_code}' \
    --resolve "${DOMAIN}:80:127.0.0.1" \
    "http://${DOMAIN}/.well-known/acme-challenge/${probe}" || true)"
  local_body="$(cat "$local_body_file" 2>/dev/null || true)"
  rm -f -- "$local_body_file"
  [ "$local_status" = 200 ] && [ "$local_body" = "$probe" ] && break
  sleep 1
done
if [ "$local_status" != 200 ] || [ "$local_body" != "$probe" ]; then
  echo 'TNA_CDN_CERT_ERROR=LOCAL_ACME_PREFLIGHT_FAILED' >&2
  echo "TNA_ACME_LOCAL_HTTP_STATUS=${local_status:-000}" >&2
  exit 162
fi

# The orange hostname must actually traverse Cloudflare.  Requiring Cf-Ray
# prevents a gray/direct DNS record from being mistaken for the CDN route.
public_body=''
public_status='000'
public_cf_ray=''
public_location=''
for _ in $(seq 1 12); do
  headers_file="$(mktemp)"
  body_file="$(mktemp)"
  public_status="$(curl --noproxy '*' --silent --show-error --max-time 8 \
    --dump-header "$headers_file" --output "$body_file" --write-out '%{http_code}' \
    -H 'Cache-Control: no-cache' -H 'Pragma: no-cache' \
    "http://${DOMAIN}/.well-known/acme-challenge/${probe}" || true)"
  public_body="$(cat "$body_file" 2>/dev/null || true)"
  public_cf_ray="$(awk 'BEGIN{IGNORECASE=1} /^cf-ray:/ {sub(/^[^:]*:[[:space:]]*/, ""); gsub(/[\r\n]/, ""); print; exit}' "$headers_file" 2>/dev/null || true)"
  public_location="$(awk 'BEGIN{IGNORECASE=1} /^location:/ {sub(/^[^:]*:[[:space:]]*/, ""); gsub(/[\r\n]/, ""); print; exit}' "$headers_file" 2>/dev/null || true)"
  rm -f -- "$headers_file" "$body_file"
  [ "$public_status" = 200 ] && [ "$public_body" = "$probe" ] && [ -n "$public_cf_ray" ] && break
  sleep 1
done
if [ "$public_status" != 200 ] || [ "$public_body" != "$probe" ] || [ -z "$public_cf_ray" ]; then
  echo 'TNA_CDN_CERT_ERROR=PUBLIC_ACME_PREFLIGHT_FAILED' >&2
  echo "TNA_ACME_PUBLIC_HTTP_STATUS=${public_status:-000}" >&2
  [ -n "$public_location" ] && echo "TNA_ACME_PUBLIC_HTTP_LOCATION=$public_location" >&2
  [ -n "$public_cf_ray" ] && echo "TNA_ACME_PUBLIC_CF_RAY=$public_cf_ray" >&2
  echo 'TNA_ACME_PUBLIC_HTTP_HINT=orange_DNS_must_be_proxied_and_HTTP_80_must_reach_origin_80;_do_not_rewrite_all_requests_to_8443' >&2
  exit 162
fi

certbot certonly --webroot -w /var/www/cover -d "$DOMAIN" \
  --agree-tos --no-eff-email --email "$EMAIL" --non-interactive --keep-until-expiring
test -s "/etc/letsencrypt/live/${DOMAIN}/fullchain.pem"
test -s "/etc/letsencrypt/live/${DOMAIN}/privkey.pem"
openssl x509 -checkend 1 -noout -in "/etc/letsencrypt/live/${DOMAIN}/fullchain.pem" >/dev/null 2>&1
echo 'TNA_CDN_CERTIFICATE_READY=1'
