#!/usr/bin/env bash
set -u
PORT="${1:-40000}"

echo "===== SERVICE ====="
systemctl status warp-svc --no-pager || true
echo
echo "===== VERSION ====="
warp-cli --version 2>/dev/null || true
echo
echo "===== SETTINGS ====="
warp-cli settings 2>/dev/null || true
echo
echo "===== STATUS ====="
warp-cli status 2>/dev/null || true
echo
echo "===== LISTENER ====="
ss -lntp | grep -E ":${PORT}[[:space:]]" || true
echo
echo "===== DIRECT EXIT ====="
curl -4fsS --max-time 15 https://api.ipify.org || true
echo
echo
echo "===== WARP SOCKS EXIT ====="
curl -4fsS --max-time 20 --proxy "socks5h://127.0.0.1:${PORT}" https://api.ipify.org || true
echo
echo
echo "===== CLOUDFLARE TRACE THROUGH WARP ====="
curl -fsS --max-time 20 --proxy "socks5h://127.0.0.1:${PORT}" https://www.cloudflare.com/cdn-cgi/trace \
  | grep -E '^(ip|warp|colo)=' || true
