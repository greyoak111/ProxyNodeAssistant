#!/usr/bin/env bash
set -u

PUB="/etc/proxy-runbook/public.env"
[ -f "$PUB" ] && . "$PUB"

ok=0
warn=0
pass(){ printf '[PASS] %s\n' "$*"; ok=$((ok+1)); }
warning(){ printf '[WARN] %s\n' "$*"; warn=$((warn+1)); }

echo "===== TEXT NODE DOCTOR ====="
PUBLIC_NOW="$(curl -4fsS --max-time 8 https://api.ipify.org 2>/dev/null || true)"
if [ -n "${PUBLIC_IP:-}" ] && [ "$PUBLIC_NOW" = "$PUBLIC_IP" ]; then
  pass "public IPv4 matches runtime metadata"
else
  warning "public IPv4=${PUBLIC_NOW:-UNKNOWN}; runtime metadata=${PUBLIC_IP:-UNSET}"
fi

systemctl is-active --quiet x-ui 2>/dev/null && pass "x-ui active" || warning "x-ui inactive/not found"
systemctl is-active --quiet nginx 2>/dev/null && pass "nginx active" || warning "nginx inactive/not found"
systemctl is-active --quiet fail2ban 2>/dev/null && pass "fail2ban active" || warning "fail2ban inactive/not found"

ss -lntp 2>/dev/null | grep -E ':443[[:space:]]' >/dev/null && pass "TCP 443 has a listener" || warning "TCP 443 has no listener"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [ -x "$ROOT/linux/23-ss2022-tcp.sh" ]; then
  SS_STATUS="$(bash "$ROOT/linux/23-ss2022-tcp.sh" status 2>/dev/null || true)"
  if grep -q '^ACTIVE=1$' <<<"$SS_STATUS" && grep -q '^LISTENER=1$' <<<"$SS_STATUS" && grep -q '^FIREWALL=1$' <<<"$SS_STATUS"; then
    SS_PORT_NOW="$(awk -F= '$1=="PORT"{print $2}' <<<"$SS_STATUS" | sed -n '1p')"
    pass "SS2022 TCP-only service/listener/firewall healthy on ${SS_PORT_NOW:-unknown}"
  else
    warning "SS2022 service/listener/firewall is incomplete"
  fi
else
  warning "SS2022 management module missing"
fi

L8443="$(ss -lntp 2>/dev/null | grep -E ':8443[[:space:]]' || true)"
if echo "$L8443" | grep -q '127.0.0.1:8443' && ! echo "$L8443" | grep -qE '0\.0\.0\.0:8443|\[::\]:8443'; then
  pass "8443 is localhost-only"
else
  warning "8443 is missing or not localhost-only"
fi

PANEL="${PANEL_PORT:-}"
if [ -n "$PANEL" ]; then
  LP="$(ss -lntp 2>/dev/null | grep -E ":${PANEL}[[:space:]]" || true)"
  if echo "$LP" | grep -q "127.0.0.1:${PANEL}" && ! echo "$LP" | grep -qE "0\.0\.0\.0:${PANEL}|\[::\]:${PANEL}"; then
    pass "3x-ui panel $PANEL is localhost-only"
  else
    warning "panel $PANEL is missing or not localhost-only"
  fi
else
  warning "panel runtime metadata not written yet"
fi

command -v nginx >/dev/null 2>&1 && nginx -t >/dev/null 2>&1 && pass "nginx -t OK" || warning "nginx config test failed"

if command -v ufw >/dev/null 2>&1; then
  U="$(ufw status 2>/dev/null || true)"
  echo "$U" | grep -q 'Status: active' && pass "UFW active" || warning "UFW inactive"
  echo "$U" | grep -qE '8443(/tcp)?[[:space:]]+ALLOW[[:space:]]+Anywhere' && warning "8443 appears publicly allowed" || pass "no obvious public UFW allow for 8443"
  echo "$U" | grep -qE '40000(/tcp)?[[:space:]]+ALLOW[[:space:]]+Anywhere' && warning "WARP local-proxy port appears publicly allowed" || pass "no obvious public UFW allow for 40000"
  if [ -n "$PANEL" ]; then
    echo "$U" | grep -qE "${PANEL}(/tcp)?[[:space:]]+ALLOW[[:space:]]+Anywhere" && warning "panel port appears publicly allowed" || pass "no obvious public UFW allow for panel"
  fi
else
  warning "ufw not installed"
fi

if systemctl is-active --quiet warp-svc 2>/dev/null; then
  pass "warp-svc active"
  WPORT="${WARP_PROXY_PORT:-40000}"
  ss -lntp 2>/dev/null | grep -E "127\.0\.0\.1:${WPORT}[[:space:]]" >/dev/null && pass "WARP Local Proxy on localhost:$WPORT" || warning "WARP localhost listener missing"
  TRACE="$(curl -fsS --max-time 20 --proxy "socks5h://127.0.0.1:${WPORT}" https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null || true)"
  echo "$TRACE" | grep -q '^warp=on' && pass "WARP trace says warp=on" || warning "WARP trace did not confirm warp=on"
else
  warning "warp-svc inactive/not found"
fi

if [ -n "${COVER_DOMAIN:-}" ] && [ -f "/etc/letsencrypt/live/${COVER_DOMAIN}/fullchain.pem" ]; then
  EXP="$(openssl x509 -enddate -noout -in "/etc/letsencrypt/live/${COVER_DOMAIN}/fullchain.pem" 2>/dev/null | cut -d= -f2-)"
  pass "cover certificate exists; expires: $EXP"
else
  warning "expected cover certificate not found"
fi

echo
echo "===== SUMMARY ====="
echo "PASS=$ok WARN=$warn"
[ "$warn" -eq 0 ] && echo "DOCTOR_GREEN" || echo "DOCTOR_HAS_WARNINGS"
