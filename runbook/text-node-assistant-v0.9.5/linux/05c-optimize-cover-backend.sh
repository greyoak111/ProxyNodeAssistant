#!/usr/bin/env bash
set -Eeuo pipefail
umask 022

DOMAIN="${1:-}"
[ "$(id -u)" -eq 0 ] || { echo "Run as root."; exit 1; }
[ -n "$DOMAIN" ] || { echo "DOMAIN is required."; exit 1; }

TOOLKIT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SUB_PROXY_SCRIPT="$TOOLKIT_ROOT/linux/32-subscription-rewrite.py"
SUB_PROXY_UNIT="$TOOLKIT_ROOT/templates/systemd/text-node-assistant-subscription-proxy.service"
SUB_PROXY_INSTALL="/usr/local/lib/text-node-assistant/subscription-rewrite.py"
SUB_PROXY_ENV="/etc/text-node-assistant/subscription-proxy.env"
SUB_PROXY_PORT=2097

[ -r "$SUB_PROXY_SCRIPT" ] || { echo "ERROR: subscription adapter is missing from the toolkit."; exit 1; }
[ -r "$SUB_PROXY_UNIT" ] || { echo "ERROR: subscription adapter systemd unit is missing from the toolkit."; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "ERROR: python3 is required for the local subscription adapter."; exit 1; }

install_subscription_adapter() {
  install -d -m 755 /usr/local/lib/text-node-assistant /etc/text-node-assistant
  install -m 755 "$SUB_PROXY_SCRIPT" "$SUB_PROXY_INSTALL"
  printf 'SUBSCRIPTION_HOST=%s\n' "$DOMAIN" > "$SUB_PROXY_ENV"
  chmod 600 "$SUB_PROXY_ENV"
  install -m 644 "$SUB_PROXY_UNIT" /etc/systemd/system/text-node-assistant-subscription-proxy.service
  systemctl daemon-reload
  systemctl enable --now text-node-assistant-subscription-proxy.service >/dev/null
  for _ in $(seq 1 20); do
    systemctl is-active --quiet text-node-assistant-subscription-proxy.service && \
      ss -lntp 2>/dev/null | grep -E "127\\.0\\.0\\.1:${SUB_PROXY_PORT}[[:space:]]" >/dev/null && return 0
    sleep 1
  done
  echo "ERROR: local subscription adapter did not become ready." >&2
  systemctl --no-pager --full status text-node-assistant-subscription-proxy.service >&2 || true
  return 1
}

install_subscription_adapter

CERT="/etc/letsencrypt/live/${DOMAIN}/fullchain.pem"
KEY="/etc/letsencrypt/live/${DOMAIN}/privkey.pem"
[ -s "$CERT" ] && [ -s "$KEY" ] || { echo "Certificate for $DOMAIN is missing."; exit 1; }

STAMP="$(date +%Y%m%d-%H%M%S)"
[ -f /etc/nginx/sites-available/cover ] && cp -a /etc/nginx/sites-available/cover "/root/nginx-cover-before-${STAMP}.conf"

cat > /etc/nginx/sites-available/cover <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${DOMAIN};

    server_tokens off;
    root /var/www/cover;
    index index.html;

    location ^~ /.well-known/acme-challenge/ {
        root /var/www/cover;
        default_type text/plain;
        auth_basic off;
        allow all;
        try_files \$uri =404;
    }

    location = /robots.txt { try_files \$uri =404; access_log off; }
    location /assets/ {
        try_files \$uri =404;
        expires 7d;
        add_header Cache-Control "public, max-age=604800, immutable";
    }
    error_page 404 /404.html;
    location = /404.html { internal; }
    location / {
        try_files \$uri \$uri/ =404;
    }
}

server {
    # Compatible with Ubuntu 22.04's Nginx 1.18 as well as newer releases.
    listen 127.0.0.1:8443 ssl http2;
    server_name ${DOMAIN};

    server_tokens off;
    ssl_certificate ${CERT};
    ssl_certificate_key ${KEY};
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_session_cache shared:proxy_cover_ssl:10m;
    ssl_session_timeout 1d;
    ssl_session_tickets off;

    add_header X-Content-Type-Options "nosniff" always;
    add_header Referrer-Policy "strict-origin-when-cross-origin" always;
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header Permissions-Policy "camera=(), microphone=(), geolocation=()" always;

    root /var/www/cover;
    index index.html;

    # 3x-ui's subscription listener stays localhost-only.  The local adapter
    # repairs generic XHTTP links (TLS/SNI/Host) after TLS is terminated here;
    # the long client sub ID remains the access token.
    location ^~ /sub/ {
        proxy_pass http://127.0.0.1:${SUB_PROXY_PORT};
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_buffering off;
        add_header Cache-Control "no-store" always;
    }

    location /assets/ {
        try_files \$uri =404;
        expires 7d;
        add_header Cache-Control "public, max-age=604800, immutable";
        add_header X-Content-Type-Options "nosniff" always;
    }
    error_page 404 /404.html;
    location = /404.html { internal; }
    location / {
        try_files \$uri \$uri/ =404;
    }
}
EOF

ln -sfn /etc/nginx/sites-available/cover /etc/nginx/sites-enabled/cover
rm -f /etc/nginx/sites-enabled/default
nginx -t
systemctl reload nginx

LINE="$(ss -lntp | grep ':8443' || true)"
echo "$LINE" | grep -q '127.0.0.1:8443' || { echo "ERROR: 8443 localhost listener missing."; exit 1; }
if echo "$LINE" | grep -qE '0\.0\.0\.0:8443|\[::\]:8443'; then
  echo "ERROR: 8443 is publicly bound."
  exit 1
fi

curl -fsS --max-time 10 --resolve "${DOMAIN}:8443:127.0.0.1" "https://${DOMAIN}:8443/" >/dev/null
echo "COVER_BACKEND_OPTIMAL backup=/root/nginx-cover-before-${STAMP}.conf"
