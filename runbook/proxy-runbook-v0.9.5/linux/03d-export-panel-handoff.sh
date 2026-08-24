#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/linux/lib-handoff.sh"
. "$ROOT/linux/lib-xui-api.sh"

MODE="${1:-existing}"
XUI="/usr/local/x-ui/x-ui"
[ -x "$XUI" ] || exit 0

if [ "$MODE" = "FRESH" ] && [ -r /etc/x-ui/install-result.env ]; then
  while IFS='=' read -r k v; do
    case "$k" in
      XUI_USERNAME) handoff_set "PANEL_USERNAME" "$v" ;;
      XUI_PASSWORD) handoff_set "PANEL_PASSWORD" "$v" ;;
      XUI_WEB_BASE_PATH) handoff_set "PANEL_WEB_BASE_PATH" "$v" ;;
      XUI_PANEL_PORT) handoff_set "PANEL_PORT" "$v" ;;
      XUI_API_TOKEN) handoff_set "PANEL_API_TOKEN" "$v" ;;
    esac
  done < /etc/x-ui/install-result.env
fi

if [ "$MODE" = "FRESH" ]; then
  FRESH_USERNAME="$(credential_value_from_file "$HANDOFF_FILE" PANEL_USERNAME 2>/dev/null || true)"
  FRESH_PASSWORD="$(credential_value_from_file "$HANDOFF_FILE" PANEL_PASSWORD 2>/dev/null || true)"
  if [ -n "$FRESH_USERNAME" ] && [ -n "$FRESH_PASSWORD" ]; then
    credential_store_set PANEL_USERNAME "$FRESH_USERNAME"
    credential_store_set PANEL_PASSWORD "$FRESH_PASSWORD"
  fi
fi
handoff_restore_stored_login_credentials

SHOW="$("$XUI" setting -show 2>/dev/null || true)"
PORT="$(printf '%s\n' "$SHOW" | sed -nE 's/^[[:space:]]*(port|panelPort):[[:space:]]*([0-9]+).*$/\2/p' | sed -n '1p')"
PATH_RAW="$(printf '%s\n' "$SHOW" | sed -nE 's/^[[:space:]]*(webBasePath|web base path):[[:space:]]*(.*)$/\2/p' | sed -n '1p')"
TOKEN=''
if xui_api_context; then
  TOKEN="$XUI_API_TOKEN"
fi

if [ -r /etc/x-ui/install-result.env ]; then
  [ -n "$PORT" ] || PORT="$(sed -n 's/^XUI_PANEL_PORT=//p' /etc/x-ui/install-result.env | sed -n '1p')"
  [ -n "$PATH_RAW" ] || PATH_RAW="$(sed -n 's/^XUI_WEB_BASE_PATH=//p' /etc/x-ui/install-result.env | sed -n '1p')"
fi

[ -n "$PORT" ] && handoff_set "PANEL_PORT" "$PORT"
[ -n "$PATH_RAW" ] && handoff_set "PANEL_WEB_BASE_PATH" "$PATH_RAW"
[ -n "$TOKEN" ] && handoff_set "PANEL_API_TOKEN" "$TOKEN"

echo
echo "================ CURRENT 3X-UI HANDOFF =================="
grep -E '^PANEL_' "$HANDOFF_FILE" || true
echo "========================================================="
if ! grep -q '^PANEL_PASSWORD=' "$HANDOFF_FILE"; then
  echo "PANEL_CREDENTIAL_FORM_INCOMPLETE=1"
  echo "The current hashed panel password cannot be reconstructed; a complete handoff requires explicit rotation."
fi
