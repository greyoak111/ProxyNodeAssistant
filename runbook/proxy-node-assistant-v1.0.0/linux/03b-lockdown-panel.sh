#!/usr/bin/env bash
set -Eeuo pipefail

[ "$(id -u)" -eq 0 ] || { echo "Run as root."; exit 1; }
XUI="/usr/local/x-ui/x-ui"
[ -x "$XUI" ] || { echo "3x-ui not found."; exit 1; }

SHOW="$("$XUI" setting -show 2>/dev/null || true)"
PORT="$(printf '%s\n' "$SHOW" | sed -nE 's/^[[:space:]]*(port|panelPort):[[:space:]]*([0-9]+).*$/\2/p' | sed -n '1p')"
[ -n "$PORT" ] || { echo "Could not discover current panel port."; exit 1; }

echo "Current panel port: $PORT"
echo "The port will be preserved; only listen address will converge to localhost."
"$XUI" setting -listenIP 127.0.0.1
systemctl restart x-ui
sleep 2

LINES="$(ss -lntp | grep -E ":${PORT}[[:space:]]" || true)"
printf '%s\n' "$LINES"
printf '%s\n' "$LINES" | grep -q "127.0.0.1:${PORT}" || {
  echo "ERROR: panel is not listening on localhost:$PORT."
  exit 1
}
if printf '%s\n' "$LINES" | grep -qE "0\.0\.0\.0:${PORT}|\[::\]:${PORT}"; then
  echo "ERROR: panel is still publicly bound."
  exit 1
fi
echo "PANEL_LOCALHOST_ONLY_OK port=$PORT"
