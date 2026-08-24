#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
grep -q 'CURRENT-LOGIN-CREDENTIALS.env' "$ROOT/runbook/proxy-runbook-v0.9.5/linux/lib-handoff.sh"
grep -q 'handoff_restore_stored_login_credentials' "$ROOT/runbook/proxy-runbook-v0.9.5/linux/lib-handoff.sh"
grep -q '完整交接表必须包含' "$ROOT/runbook/proxy-runbook-v0.9.5/linux/00-auto-install-or-optimize.sh"
grep -q 'handoff_login_form_complete || exit 85' "$ROOT/runbook/proxy-runbook-v0.9.5/linux/00-auto-install-or-optimize.sh"
grep -q 'xui_password_login_works' "$ROOT/runbook/proxy-runbook-v0.9.5/linux/03c-rotate-panel-credentials.sh"

case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*)
    echo COMPLETE_LOGIN_HANDOFF_TEST_OK
    exit 0
    ;;
esac

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export PNA_HANDOFF_DIR="$TMP/handoff"

# shellcheck source=/dev/null
. "$ROOT/runbook/proxy-runbook-v0.9.5/linux/lib-handoff.sh"

handoff_init
handoff_set VPS_LOGIN_USER root
handoff_set VPS_LOGIN_PASSWORD previous-vps-password
handoff_set PANEL_USERNAME previous-panel
handoff_set PANEL_PASSWORD previous-panel-password

handoff_begin_run
grep -qx 'VPS_LOGIN_USER=root' "$HANDOFF_FILE"
grep -qx 'VPS_LOGIN_PASSWORD=previous-vps-password' "$HANDOFF_FILE"
grep -qx 'PANEL_USERNAME=previous-panel' "$HANDOFF_FILE"
grep -qx 'PANEL_PASSWORD=previous-panel-password' "$HANDOFF_FILE"
handoff_login_form_complete

handoff_delete PANEL_PASSWORD
if handoff_login_form_complete 2>/dev/null; then
  echo 'incomplete login handoff was accepted' >&2
  exit 1
fi
credential_store_set PANEL_PASSWORD restored-panel-password
handoff_restore_stored_login_credentials
handoff_login_form_complete
grep -qx 'PANEL_PASSWORD=restored-panel-password' "$HANDOFF_FILE"

if credential_store_set PANEL_PASSWORD UNKNOWN_NOT_RECOVERABLE 2>/dev/null; then
  echo 'placeholder password entered the current-login store' >&2
  exit 1
fi

echo COMPLETE_LOGIN_HANDOFF_TEST_OK
