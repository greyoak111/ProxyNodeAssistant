#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/linux/lib-handoff.sh"
. "$ROOT/linux/lib-xui-api.sh"

XUI="/usr/local/x-ui/x-ui"
[ -x "$XUI" ] || { echo "ERROR: 3x-ui not installed."; exit 1; }

# Custom credentials are read only from a root-owned one-run 0600 file.  They
# never appear in this script's arguments, the SSH command line, or ordinary
# workflow logs.  The client removes the file after the operation; this trap
# is a second cleanup boundary for interrupted sessions.
INPUT_FILE="${PNA_CREDENTIAL_INPUT:-}"
cleanup_input() {
  [ "${PNA_CREDENTIAL_INPUT_KEEP:-0}" = "1" ] && return 0
  [[ "$INPUT_FILE" =~ ^/tmp/proxy-node-assistant-(auto-input|credential-input)-[0-9a-f]{6,64}$ ]] || return 0
  rm -f -- "$INPUT_FILE" 2>/dev/null || true
}
trap cleanup_input EXIT

validate_input_file() {
  [ -n "$INPUT_FILE" ] || { echo "ERROR: credential input file is missing." >&2; return 1; }
  [[ "$INPUT_FILE" =~ ^/tmp/proxy-node-assistant-(auto-input|credential-input)-[0-9a-f]{6,64}$ ]] || {
    echo "ERROR: credential input path is outside the one-run namespace." >&2
    return 1
  }
  [ -f "$INPUT_FILE" ] || { echo "ERROR: credential input file is missing." >&2; return 1; }
  [ ! -L "$INPUT_FILE" ] || { echo "ERROR: credential input must not be a symlink." >&2; return 1; }
  [ "$(stat -c '%u' -- "$INPUT_FILE" 2>/dev/null || echo 99999)" = "0" ] || {
    echo "ERROR: credential input is not root-owned." >&2
    return 1
  }
  case "$(stat -c '%a' -- "$INPUT_FILE" 2>/dev/null || echo 000)" in
    600|400) ;;
    *) echo "ERROR: credential input permissions must be 0600 or stricter." >&2; return 1 ;;
  esac
}

read_input_b64() {
  local key="$1" encoded decoded
  validate_input_file || return 1
  encoded="$(sed -n "s/^${key}=//p" "$INPUT_FILE" | sed -n '1p')"
  [ -n "$encoded" ] || return 1
  decoded="$(printf '%s' "$encoded" | base64 -d 2>/dev/null)" || return 1
  printf '%s' "$decoded"
}

CREDENTIAL_MODE="${PNA_PANEL_CREDENTIAL_MODE:-random}"
case "$CREDENTIAL_MODE" in
  random)
    USERNAME="panel_$(openssl rand -hex 5)"
    PASSWORD="$(openssl rand -hex 20)"
    ;;
  custom)
    USERNAME="$(read_input_b64 PANEL_USERNAME_B64 || true)"
    PASSWORD="$(read_input_b64 PANEL_PASSWORD_B64 || true)"
    case "$USERNAME" in
      ''|*$'\r'*|*$'\n'*|*[!A-Za-z0-9_.-]*) echo "ERROR: custom panel username contains unsupported characters." >&2; exit 64 ;;
    esac
    [[ "$USERNAME" =~ ^[A-Za-z_][A-Za-z0-9_.-]{0,63}$ ]] || {
      echo "ERROR: custom panel username must start with a letter/underscore and be <=64 characters." >&2
      exit 64
    }
    case "$PASSWORD" in
      ''|*$'\r'*|*$'\n'*) echo "ERROR: custom panel password is empty or contains a newline." >&2; exit 64 ;;
    esac
    [ "${#PASSWORD}" -ge 8 ] && [ "${#PASSWORD}" -le 256 ] || {
      echo "ERROR: custom panel password length must be 8..256 characters." >&2
      exit 64
    }
    ;;
  preserve)
    echo "ERROR: preserve mode does not rotate panel credentials; use the installer retention path." >&2
    exit 64
    ;;
  *)
    echo "ERROR: unknown panel credential mode '$CREDENTIAL_MODE'." >&2
    exit 64
    ;;
esac

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
if [ "$CREDENTIAL_MODE" = "custom" ]; then
  # Keep the custom secret out of the normal command output.  It is already
  # present in the root-only handoff consumed by the client.
  echo "PANEL_CREDENTIALS_CUSTOM_APPLIED=1"
else
  echo "PANEL_PASSWORD=$PASSWORD"
fi
echo "PANEL_PORT=${PORT:-unknown}"
echo "PANEL_WEB_BASE_PATH=${PATH_RAW:-unknown}"
echo "PANEL_API_TOKEN=${TOKEN:-unknown}"
echo "========================================================="
