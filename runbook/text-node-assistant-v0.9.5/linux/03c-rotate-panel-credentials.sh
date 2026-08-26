#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/linux/lib-handoff.sh"
. "$ROOT/linux/lib-xui-api.sh"

XUI="/usr/local/x-ui/x-ui"
[ -x "$XUI" ] || { echo "ERROR: 3x-ui not installed."; exit 1; }

USERNAME="panel_$(openssl rand -hex 5)"
PASSWORD="$(openssl rand -hex 20)"

"$XUI" setting -username "$USERNAME" -password "$PASSWORD"
systemctl restart x-ui
sleep 2

SHOW="$("$XUI" setting -show 2>/dev/null || true)"
PORT="$(printf '%s\n' "$SHOW" | sed -nE 's/^[[:space:]]*(port|panelPort):[[:space:]]*([0-9]+).*$/\2/p' | sed -n '1p')"
PATH_RAW="$(printf '%s\n' "$SHOW" | sed -nE 's/^[[:space:]]*(webBasePath|web base path):[[:space:]]*(.*)$/\2/p' | sed -n '1p')"
TOKEN=''
if xui_api_context; then
  TOKEN="$XUI_API_TOKEN"
fi

handoff_set "PANEL_USERNAME" "$USERNAME"
handoff_set "PANEL_PASSWORD" "$PASSWORD"
credential_store_set "PANEL_USERNAME" "$USERNAME"
credential_store_set "PANEL_PASSWORD" "$PASSWORD"
[ -n "$PORT" ] && handoff_set "PANEL_PORT" "$PORT"
[ -n "$PATH_RAW" ] && handoff_set "PANEL_WEB_BASE_PATH" "$PATH_RAW"
[ -n "$TOKEN" ] && handoff_set "PANEL_API_TOKEN" "$TOKEN"

xui_password_login_works "$USERNAME" "$PASSWORD" || {
  echo "ERROR: new 3x-ui credentials did not pass a real localhost login check." >&2
  exit 1
}
echo "PANEL_PASSWORD_LOGIN_VERIFIED=1"

echo
echo "================ REAL 3X-UI CREDENTIALS ================="
echo "PANEL_USERNAME=$USERNAME"
echo "PANEL_PASSWORD=$PASSWORD"
echo "PANEL_PORT=${PORT:-unknown}"
echo "PANEL_WEB_BASE_PATH=${PATH_RAW:-unknown}"
echo "PANEL_API_TOKEN=${TOKEN:-unknown}"
echo "========================================================="
