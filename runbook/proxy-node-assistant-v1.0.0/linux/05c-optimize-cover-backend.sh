#!/usr/bin/env bash
set -Eeuo pipefail
umask 022

DOMAIN="${1:-}"
[ "$(id -u)" -eq 0 ] || { echo "Run as root."; exit 1; }
[ -n "$DOMAIN" ] || { echo "DOMAIN is required."; exit 1; }

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

    # 3x-ui's subscription listener stays localhost-only.  The long client
    # sub ID remains the access token; TLS is terminated by this cover vhost.
    location ^~ /sub/ {
        proxy_pass http://127.0.0.1:2096;
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
