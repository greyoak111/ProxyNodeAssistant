#!/usr/bin/env bash
set -euo pipefail

PORT="${1:-40000}"

if ! command -v warp-cli >/dev/null 2>&1; then
  echo "warp-cli not installed. Run 06-warp-install.sh first."
  exit 1
fi

WHELP="$(warp-cli --help 2>&1 || true)"
if printf '%s' "$WHELP" | grep -q -- '--accept-tos'; then
  WC=(warp-cli --accept-tos)
else
  WC=(warp-cli)
fi

echo "===== VERSION ====="
warp-cli --version || true

echo "===== REGISTRATION ====="
if ! "${WC[@]}" registration show >/dev/null 2>&1; then
  "${WC[@]}" registration new
fi
"${WC[@]}" registration show || true

echo "===== FORCE MASQUE ====="
"${WC[@]}" tunnel protocol set MASQUE

echo "===== LOCAL PROXY MODE ====="
MODE_HELP="$("${WC[@]}" mode --help 2>&1 || true)"
if printf '%s' "$MODE_HELP" | grep -qi 'proxy'; then
  "${WC[@]}" mode proxy
else
  echo "ERROR: this warp-cli does not advertise proxy mode."
  echo "Run manually and inspect:"
  echo "  warp-cli mode --help"
  exit 1
fi

echo "===== PROXY PORT ====="
PROXY_HELP="$("${WC[@]}" proxy --help 2>&1 || true)"
if printf '%s' "$PROXY_HELP" | grep -qiE 'port'; then
  if ! "${WC[@]}" proxy port "$PORT"; then
    echo "Could not set proxy port explicitly."
    echo "Cloudflare Local Proxy defaults to 40000; continuing only if requested port is 40000."
    [ "$PORT" = "40000" ] || exit 1
  fi
else
  echo "This CLI has no 'proxy port' subcommand."
  echo "Cloudflare Local Proxy default is 40000."
  [ "$PORT" = "40000" ] || {
    echo "Use port 40000 or inspect 'warp-cli --help' for this installed version."
    exit 1
  }
fi

echo "===== CONNECT ====="
"${WC[@]}" connect
sleep 3

echo "===== SETTINGS ====="
"${WC[@]}" settings || true
echo "===== STATUS ====="
"${WC[@]}" status || true

echo "===== LOCAL LISTENER ====="
ss -lntp | grep -E ":${PORT}[[:space:]]" || {
  echo "No listener found on ${PORT}."
  echo "Collect diagnostics with: warp-diag"
  exit 1
}

echo "===== SOCKS5 TEST ====="
TRACE="$(curl --fail --silent --show-error --max-time 20 \
  --proxy "socks5h://127.0.0.1:${PORT}" \
  https://www.cloudflare.com/cdn-cgi/trace)"
printf '%s\n' "$TRACE" | grep -E '^(ip|warp|colo)=' || true
printf '%s\n' "$TRACE" | grep -q '^warp=on$' || {
  echo "WARP proxy answered but trace did not say warp=on."
  exit 1
}

echo
echo "WARP_PROXY_OK port=${PORT}"
