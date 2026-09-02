#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/linux/lib-handoff.sh"

LOGIN_USER="${1:-${PROXY_RUNBOOK_LOGIN_USER:-${SUDO_USER:-root}}}"
getent passwd "$LOGIN_USER" >/dev/null || {
  echo "ERROR: user '$LOGIN_USER' does not exist."
  exit 1
}

# A custom password is accepted only through a root-owned, one-run 0600 input
# file.  It is deliberately not an argument or environment value: SSH's
# command line, process listings, and shell history must never contain it.
# The desktop/Android clients upload this file over the already-authenticated
# SSH stdin channel and remove it after this command.  The script also removes
# it on exit as a last-resort cleanup for interrupted runs.
INPUT_FILE="${PNA_CREDENTIAL_INPUT:-}"
cleanup_input() {
  [ "${PNA_CREDENTIAL_INPUT_KEEP:-0}" = "1" ] && return 0
  [[ "$INPUT_FILE" =~ ^/tmp/proxy-node-assistant-(auto-input|credential-input)-[0-9a-f]{6,64}$ ]] || return 0
  rm -f -- "$INPUT_FILE" 2>/dev/null || true
}
trap cleanup_input EXIT

validate_input_file() {
  [ -n "$INPUT_FILE" ] || { echo "ERROR: credential input file is missing." >&2; return 1; }
  # Restrict the path to the client-created one-run namespace.  In addition to
  # preventing path traversal, reject symlinks before reading a root-owned
  # file; the writer uses O_EXCL/noclobber so this check closes both sides of
  # the /tmp replacement race.
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

PASSWORD_MODE="${PNA_VPS_PASSWORD_MODE:-random}"
case "$PASSWORD_MODE" in
  random)
    PASSWORD="$(openssl rand -hex 20)"
    ;;
  custom)
    PASSWORD="$(read_input_b64 VPS_PASSWORD_B64 || true)"
    case "$PASSWORD" in
      ''|*$'\r'*|*$'\n'*) echo "ERROR: custom VPS password is empty or contains a newline." >&2; exit 64 ;;
    esac
    [ "${#PASSWORD}" -ge 8 ] && [ "${#PASSWORD}" -le 256 ] || {
      echo "ERROR: custom VPS password length must be 8..256 characters." >&2
      exit 64
    }
    ;;
  preserve)
    echo "ERROR: preserve mode does not rotate a VPS password; use the installer handoff path." >&2
    exit 64
    ;;
  *)
    echo "ERROR: unknown VPS password mode '$PASSWORD_MODE'." >&2
    exit 64
    ;;
esac
printf '%s:%s\n' "$LOGIN_USER" "$PASSWORD" | chpasswd

handoff_set "VPS_LOGIN_USER" "$LOGIN_USER"
handoff_set "VPS_LOGIN_PASSWORD" "$PASSWORD"

echo
echo "================ REAL VPS LOGIN PASSWORD ================"
echo "VPS_LOGIN_USER=$LOGIN_USER"
if [ "$PASSWORD_MODE" = "random" ]; then
  echo "VPS_LOGIN_PASSWORD=$PASSWORD"
else
  # The real value is in the root-only handoff and is fetched by the client
  # through its secret-hand-off path; do not stream it into an ordinary log.
  echo "VPS_LOGIN_PASSWORD_CUSTOM_APPLIED=1"
fi
echo "========================================================="
if [ "$PASSWORD_MODE" = "random" ]; then
  echo "The password was generated locally on this VPS and is shown in full."
else
  echo "The custom password was applied; the real value is retained in the root-only handoff."
fi
echo "A root-only copy is kept in $HANDOFF_FILE"
