#!/usr/bin/env bash
set -Eeuo pipefail

PUBLIC_ENV="/etc/text-node-assistant/public.env"
INSTALL_ENV="/etc/x-ui/install-result.env"
XUI="/usr/local/x-ui/x-ui"

PORT=""
WEB_PATH=""
SOURCE=""

read_env_value() {
  local file="$1" key="$2"
  [ -r "$file" ] || return 0
  sed -n "s/^${key}=//p" "$file" | sed -n '1p'
}

valid_port() {
  [[ "${1:-}" =~ ^[0-9]+$ ]] && [ "$1" -ge 1 ] && [ "$1" -le 65535 ]
}

valid_path() {
  local value="${1:-}"
  [ -n "$value" ] || return 1
  [[ "$value" =~ ^/?[A-Za-z0-9._~/-]+/?$ ]]
}

PORT="$(read_env_value "$PUBLIC_ENV" PANEL_PORT)"
WEB_PATH="$(read_env_value "$PUBLIC_ENV" WEB_BASE_PATH)"
if valid_port "$PORT" && valid_path "$WEB_PATH"; then
  SOURCE="public.env"
else
  PORT=""
  WEB_PATH=""
fi

if [ -z "$SOURCE" ] && [ -x "$XUI" ]; then
  SHOW="$("$XUI" setting -show 2>/dev/null || true)"
  PORT="$(printf '%s\n' "$SHOW" | sed -nE 's/^[[:space:]]*(port|panelPort):[[:space:]]*([0-9]+).*$/\2/p' | sed -n '1p')"
  WEB_PATH="$(printf '%s\n' "$SHOW" | sed -nE 's/^[[:space:]]*(webBasePath|web base path):[[:space:]]*(.*)$/\2/p' | sed -n '1p')"
  if valid_port "$PORT" && valid_path "$WEB_PATH"; then
    SOURCE="x-ui-setting"
  else
    PORT=""
    WEB_PATH=""
  fi
fi

if [ -z "$SOURCE" ]; then
  PORT="$(read_env_value "$INSTALL_ENV" XUI_PANEL_PORT)"
  WEB_PATH="$(read_env_value "$INSTALL_ENV" XUI_WEB_BASE_PATH)"
  if valid_port "$PORT" && valid_path "$WEB_PATH"; then
    SOURCE="install-result.env"
  fi
fi

if ! valid_port "$PORT" || ! valid_path "$WEB_PATH"; then
  echo "PANEL_METADATA_ERROR=port_or_path_not_found" >&2
  exit 12
fi

case "$WEB_PATH" in
  /*) ;;
  *) WEB_PATH="/$WEB_PATH" ;;
esac
case "$WEB_PATH" in
  */) ;;
  *) WEB_PATH="$WEB_PATH/" ;;
esac

echo "__TNA_PANEL_META_BEGIN__"
echo "PANEL_PORT=$PORT"
echo "WEB_BASE_PATH=$WEB_PATH"
echo "PANEL_METADATA_SOURCE=$SOURCE"
echo "__TNA_PANEL_META_END__"
