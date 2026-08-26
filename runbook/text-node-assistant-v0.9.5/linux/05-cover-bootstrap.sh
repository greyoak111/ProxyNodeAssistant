#!/usr/bin/env bash
set -euo pipefail
umask 022

PUBLIC_DIR="/etc/text-node-assistant"
COVER_STATUS_FILE="$PUBLIC_DIR/cover-last-run.env"
COVER_STAGE="INITIALIZATION"
COVER_COMPLETE=0
PROBE_PATH=""

cover_status() {
  local status="$1" rc="${2:-0}" tmp
  mkdir -p "$PUBLIC_DIR"
  tmp="$(mktemp)"
  {
    printf 'COVER_STATUS=%s\n' "$status"
    printf 'COVER_STAGE=%s\n' "$COVER_STAGE"
    printf 'COVER_EXIT_CODE=%s\n' "$rc"
    printf 'COVER_UPDATED=%s\n' "$(date -Is)"
  } > "$tmp"
  install -m 644 "$tmp" "$COVER_STATUS_FILE"
  rm -f "$tmp"
}

cover_exit() {
  local rc=$?
  if [ -n "${PROBE_PATH:-}" ]; then
    rm -f -- "$PROBE_PATH" 2>/dev/null || true
  fi
  if [ "$rc" -ne 0 ] && [ "$COVER_COMPLETE" -ne 1 ]; then
    cover_status FAILED "$rc" 2>/dev/null || true
    printf '\nTNA_COVER_FAILURE stage=%s rc=%s\n' "$COVER_STAGE" "$rc" >&2
  fi
}
trap cover_exit EXIT

if [ "$(id -u)" -ne 0 ]; then
  echo "Run as root."
  exit 1
fi

DOMAIN="${DOMAIN:-${1:-}}"
EMAIL="${EMAIL:-${2:-}}"

if [ -z "${DOMAIN:-}" ]; then
  read -r -p "Cover domain (example: cover.example.com): " DOMAIN
fi
if [ -z "${EMAIL:-}" ]; then
  read -r -p "Email for Let's Encrypt notices: " EMAIL
fi

if [[ ! "$DOMAIN" =~ ^[A-Za-z0-9.-]+$ ]] || [[ "$DOMAIN" != *.* ]]; then
  echo "Invalid domain."
  exit 1
fi
if [[ "$EMAIL" != *@*.* ]]; then
  echo "Invalid email."
  exit 1
fi

COVER_STAGE="DNS_CHECK"
cover_status RUNNING 0
echo "===== DNS CHECK ====="
getent ahostsv4 "$DOMAIN" || {
  echo "DNS does not resolve yet. Create the A record first, then rerun."
  exit 1
}

install -d -m 755 /var/www/cover /var/www/cover/.well-known /var/www/cover/.well-known/acme-challenge
COVER_STAGE="COVER_FRONTEND"
cover_status RUNNING 0
bash "$(dirname "$0")/05b-cover-site-polished.sh" "$DOMAIN" auto "${TNA_COVER_TEMPLATE:-auto}" || {
  rc=$?
  if [ "$rc" -eq 20 ]; then
    echo "Custom existing cover site preserved."
  else
    exit "$rc"
  fi
}

COVER_STAGE="NGINX_HTTP_CONFIG"
cover_status RUNNING 0
cat > /etc/nginx/sites-available/cover <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${DOMAIN};

    root /var/www/cover;
    index index.html;

    location ^~ /.well-known/acme-challenge/ {
        root /var/www/cover;
        default_type text/plain;
        auth_basic off;
        allow all;
        try_files \$uri =404;
    }

    location / {
        try_files \$uri \$uri/ =404;
    }
}
EOF

ln -sfn /etc/nginx/sites-available/cover /etc/nginx/sites-enabled/cover
rm -f /etc/nginx/sites-enabled/default

# Put the random challenge in place before reload.  systemctl reload can return
# while an old nginx worker is still briefly accepting connections, so an
# immediate one-shot request can otherwise produce a false 404.
PROBE_NAME="text-node-assistant-$(openssl rand -hex 16)"
PROBE_VALUE="${PROBE_NAME}-ok"
PROBE_PATH="/var/www/cover/.well-known/acme-challenge/${PROBE_NAME}"
printf '%s\n' "$PROBE_VALUE" > "$PROBE_PATH"
chmod 644 "$PROBE_PATH"

nginx -t
systemctl reload nginx

echo "===== LOCAL HTTP CHECK ====="
COVER_STAGE="LOCAL_HTTP_CHECK"
cover_status RUNNING 0
curl -fsSI -H "Host: ${DOMAIN}" http://127.0.0.1/ | sed -n '1,10p'

echo "===== PUBLIC ACME HTTP PREFLIGHT ====="
COVER_STAGE="PUBLIC_ACME_HTTP_PREFLIGHT"
cover_status RUNNING 0
LOCAL_PROBE=""
for attempt in $(seq 1 40); do
  LOCAL_PROBE="$(curl --noproxy '*' --fail --silent --max-time 2 \
    -H 'Connection: close' -H "Host: ${DOMAIN}" \
    "http://127.0.0.1/.well-known/acme-challenge/${PROBE_NAME}" || true)"
  [ "$LOCAL_PROBE" = "$PROBE_VALUE" ] && break
  sleep 0.25
done
if [ "$LOCAL_PROBE" != "$PROBE_VALUE" ]; then
  echo "TNA_ACME_LOCAL_PREFLIGHT_FAILURE"
  echo "Nginx did not serve its own ACME challenge after waiting for the reloaded workers. Check the active server block and /var/www/cover permissions."
  exit 31
fi

PUBLIC_PROBE=""
for attempt in $(seq 1 10); do
  PUBLIC_PROBE="$(curl --noproxy '*' --fail --silent --max-time 4 \
    -H 'Connection: close' \
    "http://${DOMAIN}/.well-known/acme-challenge/${PROBE_NAME}" || true)"
  [ "$PUBLIC_PROBE" = "$PROBE_VALUE" ] && break
  sleep 1
done
if [ "$PUBLIC_PROBE" != "$PROBE_VALUE" ]; then
  echo "TNA_ACME_PUBLIC_PREFLIGHT_FAILURE"
  echo "The public domain cannot download the ACME challenge although the local Nginx check passed."
  echo "Check inherited Nginx allow/deny or authentication rules, duplicate port-80 server blocks, and upstream HTTP filtering."
  exit 32
fi
rm -f -- "$PROBE_PATH"
PROBE_PATH=""
echo "PUBLIC_ACME_HTTP_PREFLIGHT_OK"

echo "===== CERTIFICATE ====="
COVER_STAGE="CERTIFICATE_ISSUANCE"
cover_status RUNNING 0
certbot certonly \
  --webroot -w /var/www/cover \
  -d "$DOMAIN" \
  --agree-tos \
  --no-eff-email \
  --email "$EMAIL" \
  --non-interactive \
  --keep-until-expiring

test -s "/etc/letsencrypt/live/${DOMAIN}/fullchain.pem"
test -s "/etc/letsencrypt/live/${DOMAIN}/privkey.pem"

COVER_STAGE="NGINX_TLS_BACKEND"
cover_status RUNNING 0
bash "$(dirname "$0")/05c-optimize-cover-backend.sh" "$DOMAIN"

mkdir -p /etc/letsencrypt/renewal-hooks/deploy
cat > /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh <<'EOF'
#!/usr/bin/env bash
set -e
nginx -t
systemctl reload nginx
EOF
chmod 755 /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh

echo "===== 8443 LISTEN CHECK ====="
COVER_STAGE="LOCALHOST_8443_CHECK"
cover_status RUNNING 0
LINE="$(ss -lntp | grep ':8443' || true)"
echo "$LINE"
echo "$LINE" | grep -q '127.0.0.1:8443' || {
  echo "ERROR: expected nginx on 127.0.0.1:8443"
  exit 1
}
if echo "$LINE" | grep -qE '0\.0\.0\.0:8443|\[::\]:8443'; then
  echo "ERROR: 8443 is publicly bound. Stop and fix before continuing."
  exit 1
fi

echo "===== LOCAL TLS CHECK ====="
COVER_STAGE="LOCAL_TLS_CHECK"
cover_status RUNNING 0
curl --fail --silent --show-error \
  --resolve "${DOMAIN}:8443:127.0.0.1" \
  "https://${DOMAIN}:8443/" >/dev/null

echo "===== CERTBOT TIMER / DRY-RUN ====="
COVER_STAGE="CERTBOT_RENEWAL_DRY_RUN"
cover_status RUNNING 0
systemctl list-timers --all | grep -i certbot || true
if ! certbot renew --dry-run; then
  echo "WARNING: certificate is installed, but the renewal dry-run failed."
  echo "Run certbot renew --dry-run again after checking DNS and outbound connectivity."
fi

echo
echo "COVER_OK"
echo "Reality target: 127.0.0.1:8443"
echo "Reality serverName/SNI: ${DOMAIN}"
echo "Do NOT open public 8443 in UFW."

COVER_COMPLETE=1
COVER_STAGE="COMPLETE"
cover_status SUCCESS 0
trap - EXIT
