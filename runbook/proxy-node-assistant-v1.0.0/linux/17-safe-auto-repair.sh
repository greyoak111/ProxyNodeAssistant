#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PUB="/etc/proxy-runbook/public.env"
[ -f "$PUB" ] && . "$PUB"

[ "$(id -u)" -eq 0 ] || { echo "Run as root."; exit 1; }

echo "===== SAFE AUTO REPAIR ====="
bash "$ROOT/linux/01-safe-backup.sh"

SSH_PORT_NOW="$(sshd -T 2>/dev/null | awk '$1=="port" && !found {print $2; found=1}')"
SSH_PORT_NOW="${SSH_PORT_NOW:-22}"

systemctl enable --now nginx 2>/dev/null || true
systemctl enable --now x-ui 2>/dev/null || true
systemctl enable --now fail2ban 2>/dev/null || true

if [ -x "$ROOT/linux/23-ss2022-tcp.sh" ] && [ -s /etc/proxy-runbook/ss2022/service.env ]; then
  SS_PORT_NOW="$(sed -n 's/^PORT=//p' /etc/proxy-runbook/ss2022/service.env | sed -n '1p')"
  # Preserve an explicitly recorded legacy/trial port (including 30443).
  # Only a missing metadata value uses the v1 formal default.
  bash "$ROOT/linux/23-ss2022-tcp.sh" ensure "${SS_PORT_NOW:-32443}" || true
fi

if command -v ufw >/dev/null 2>&1; then
  ufw allow "${SSH_PORT_NOW}/tcp"
  ufw allow 80/tcp
  ufw allow 443/tcp
  ufw --force enable
fi

if [ -x /usr/local/x-ui/x-ui ] && [ -n "${PANEL_PORT:-}" ]; then
  L="$(ss -lntp 2>/dev/null | grep -E ":${PANEL_PORT}[[:space:]]" || true)"
  if ! echo "$L" | grep -q "127.0.0.1:${PANEL_PORT}" || echo "$L" | grep -qE "0\.0\.0\.0:${PANEL_PORT}|\[::\]:${PANEL_PORT}"; then
    /usr/local/x-ui/x-ui setting -listenIP 127.0.0.1
    systemctl restart x-ui
    sleep 2
  fi
fi

if [ -n "${COVER_DOMAIN:-}" ] && [ -s "/etc/letsencrypt/live/${COVER_DOMAIN}/fullchain.pem" ]; then
  if ! openssl x509 -checkend $((14*86400)) -noout -in "/etc/letsencrypt/live/${COVER_DOMAIN}/fullchain.pem" >/dev/null 2>&1; then
    certbot renew --non-interactive || true
  fi
fi

if command -v warp-cli >/dev/null 2>&1; then
  systemctl enable --now warp-svc 2>/dev/null || true
  TRACE="$(curl -fsS --max-time 15 --proxy socks5h://127.0.0.1:40000 https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null || true)"
  if ! echo "$TRACE" | grep -q '^warp=on'; then
    bash "$ROOT/linux/07-warp-configure-proxy.sh" 40000 || true
  fi
fi

if [ -n "${COVER_DOMAIN:-}" ] && [ -f /var/www/cover/index.html ] && \
   grep -qE 'This site is online|<h1>Welcome</h1>' /var/www/cover/index.html; then
  bash "$ROOT/linux/05b-cover-site-polished.sh" "$COVER_DOMAIN" auto || true
fi

if [ -n "${COVER_DOMAIN:-}" ] && [ -f /var/www/cover/.proxy-runbook-cover ] && \
   [ -s "/etc/letsencrypt/live/${COVER_DOMAIN}/fullchain.pem" ]; then
  bash "$ROOT/linux/05c-optimize-cover-backend.sh" "$COVER_DOMAIN" || true
  bash "$ROOT/linux/05d-configure-subscription.sh" "$COVER_DOMAIN" 2096 || true
fi

if [ -n "${PUBLIC_IP:-}" ]; then
  if bash "$ROOT/linux/04a-reality-api.sh" inspect-443 "${COVER_DOMAIN:-}" "$PUBLIC_IP" >/dev/null 2>&1; then
    :
  else
    INSPECT_RC=$?
    if [ "$INSPECT_RC" -eq 4 ]; then
      bash "$ROOT/linux/04a-reality-api.sh" normalize-share "$PUBLIC_IP" || true
    fi
  fi
fi

nginx -t 2>/dev/null || true
echo "SAFE_REPAIR_FINISHED"
echo
bash "$ROOT/linux/16-auto-diagnose.sh"
