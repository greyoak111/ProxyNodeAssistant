#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/linux/lib-handoff.sh"

LOGIN_USER="${1:-${TNA_LOGIN_USER:-${SUDO_USER:-root}}}"
getent passwd "$LOGIN_USER" >/dev/null || {
  echo "ERROR: user '$LOGIN_USER' does not exist."
  exit 1
}

PASSWORD="$(openssl rand -hex 20)"
printf '%s:%s\n' "$LOGIN_USER" "$PASSWORD" | chpasswd

handoff_set "VPS_LOGIN_USER" "$LOGIN_USER"
handoff_set "VPS_LOGIN_PASSWORD" "$PASSWORD"
credential_store_set "VPS_LOGIN_USER" "$LOGIN_USER"
credential_store_set "VPS_LOGIN_PASSWORD" "$PASSWORD"

echo
echo "================ REAL VPS LOGIN PASSWORD ================"
echo "VPS_LOGIN_USER=$LOGIN_USER"
echo "VPS_LOGIN_PASSWORD=$PASSWORD"
echo "========================================================="
echo "The password was generated locally on this VPS and is shown in full."
echo "A root-only copy is kept in $HANDOFF_FILE"
