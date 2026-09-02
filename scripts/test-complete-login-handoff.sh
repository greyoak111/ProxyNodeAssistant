#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ROOT/runbook/proxy-node-assistant-v1.0.0/linux/lib-handoff.sh"
INSTALLER="$ROOT/runbook/proxy-node-assistant-v1.0.0/linux/00-auto-install-or-optimize.sh"
PANEL_ROTATE="$ROOT/runbook/proxy-node-assistant-v1.0.0/linux/03c-rotate-panel-credentials.sh"
PANEL_EXPORT="$ROOT/runbook/proxy-node-assistant-v1.0.0/linux/03d-export-panel-handoff.sh"
XUI_API="$ROOT/runbook/proxy-node-assistant-v1.0.0/linux/lib-xui-api.sh"

grep -q 'CURRENT-LOGIN-CREDENTIALS.env' "$LIB"
grep -q 'handoff_restore_stored_login_credentials' "$LIB"
grep -q 'handoff_login_form_complete' "$INSTALLER"
grep -q 'xui_password_login_works' "$PANEL_ROTATE"
grep -q 'credential_store_set' "$PANEL_EXPORT"
grep -q 'credential_store_seed_from_handoffs' "$PANEL_EXPORT"

# GUI runs must not print the raw credential handoff into the workflow log;
# the GUI retrieves the verified block through its protected parser instead.
# Keep the CLI path unchanged (it still calls handoff_show).
gui_guard_line="$(grep -Fn 'PROXY_RUNBOOK_GUI_MODE' "$INSTALLER" | tail -n 1 | cut -d: -f1)"
gui_ready_line="$(grep -Fn 'CREDENTIAL_HANDOFF_READY=1' "$INSTALLER" | tail -n 1 | cut -d: -f1)"
cli_show_line="$(grep -nE '^[[:space:]]*handoff_show[[:space:]]*$' "$INSTALLER" | tail -n 1 | cut -d: -f1)"
if [ -z "$gui_guard_line" ] || [ -z "$gui_ready_line" ] || [ -z "$cli_show_line" ] || \
   [ "$gui_guard_line" -ge "$gui_ready_line" ] || [ "$gui_ready_line" -ge "$cli_show_line" ]; then
  echo 'installer does not guard raw handoff output in GUI mode' >&2
  exit 1
fi

# The direct maintenance menu must apply the same retirement boundary as the
# desktop/Android canonical formatter.  In particular, a bare
# CURRENT_DEVICE_ID used to slip through because it has no DEVICE_ prefix.
# Keep this probe before the platform-specific early exit so it also runs on
# Windows Git Bash, where the rest of this fixture is intentionally skipped.
. "$LIB"
legacy_header='===== '"TNA COMPLETE HANDOFF v0.9.5"' ====='
legacy_footer='===== END '"TNA COMPLETE HANDOFF v0.9.5"' ====='
displayed="$(printf '%s\n' \
  "$legacy_header" \
  'PRIVATE_DRIVE_MODE=copyparty' \
  'CURRENT_DEVICE_ID=old-device' \
  'DEVICE_ID=old-device-2' \
  'CONTROLLER_ACTIVE_COUNT=1' \
  'FUTURE_UNKNOWN_FIELD=preserve-me' \
  "$legacy_footer" | handoff_display_file /dev/stdin)"
if printf '%s\n' "$displayed" | grep -Eq 'TNA COMPLETE HANDOFF|PRIVATE_DRIVE_|CURRENT_DEVICE_ID=|DEVICE_ID=|CONTROLLER_'; then
  echo 'retired handoff presentation state leaked through display filter' >&2
  exit 1
fi
printf '%s\n' "$displayed" | grep -q '^FUTURE_UNKNOWN_FIELD=preserve-me$'

# Legacy CDN/XHTTP handoffs used TNA fragments and the XHTTP_LINK alias.
# The file itself remains a migration source, but the maintenance display must
# expose one canonical PNA key while preserving optional transport query bytes.
legacy_cdn='vless://11111111-1111-4111-8111-111111111111@edge.example.com:8443?type=xhttp&encryption=none&path=%2F0123456789abcdef0123456789abcdef%2F&host=edge.example.com&mode=packet-up&security=tls&sni=edge.example.com&fp=chrome&x_padding_bytes=100-1000&extra=%7B%22mode%22%3A%22packet-up%22%7D#TNA-CDN-XHTTP-ORANGE'
cdn_displayed="$(printf '%s\n' \
  "CDN_XHTTP_LINK=$legacy_cdn" \
  "XHTTP_LINK=$legacy_cdn" | handoff_display_file /dev/stdin)"
if printf '%s\n' "$cdn_displayed" | grep -q 'TNA-CDN-XHTTP\|^XHTTP_LINK='; then
  echo 'legacy CDN/XHTTP alias leaked through display filter' >&2
  exit 1
fi
printf '%s\n' "$cdn_displayed" | grep -q '^CDN_XHTTP_LINK=.*#PNA-CDN-XHTTP-ORANGE$'
printf '%s\n' "$cdn_displayed" | grep -q 'x_padding_bytes=100-1000'
printf '%s\n' "$cdn_displayed" | grep -q 'extra=%7B%22mode%22%3A%22packet-up%22%7D'
test "$(printf '%s\n' "$cdn_displayed" | grep -c '^CDN_XHTTP_LINK=')" -eq 1

# v0.9.x handoffs may still use VPS_ACCOUNT/VPS_PASSWORD and XUI_* names.
# The shell reader must normalize those aliases without printing any value.
legacy_alias_payload="$(printf '%s\n' \
  'VPS_LOGIN_USER=UNKNOWN_NOT_RETAINED' \
  'VPS_ACCOUNT=alias-root' \
  'VPS_PASSWORD=alias-vps-password' \
  'PANEL_ACCOUNT=alias-panel' \
  'XUI_USERNAME=xui-panel' \
  'XUI_PASSWORD=xui-panel-password')"
test "$(printf '%s\n' "$legacy_alias_payload" | credential_value_from_file /dev/stdin VPS_LOGIN_USER)" = alias-root
test "$(printf '%s\n' "$legacy_alias_payload" | credential_value_from_file /dev/stdin VPS_LOGIN_PASSWORD)" = alias-vps-password
test "$(printf '%s\n' "$legacy_alias_payload" | credential_value_from_file /dev/stdin PANEL_USERNAME)" = xui-panel
test "$(printf '%s\n' "$legacy_alias_payload" | credential_value_from_file /dev/stdin PANEL_PASSWORD)" = xui-panel-password

case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*) echo COMPLETE_LOGIN_HANDOFF_TEST_OK; exit 0 ;;
esac

TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT
export PNA_HANDOFF_DIR="$TMP/new"
export PNA_LEGACY_HANDOFF_DIR="$TMP/legacy"
mkdir -p "$PNA_LEGACY_HANDOFF_DIR"
printf '%s\n' \
  'HANDOFF_RUN_STARTED=fixture' \
  'VPS_LOGIN_USER=legacy-root' \
  'VPS_LOGIN_PASSWORD=fixture-vps' \
  'PANEL_USERNAME=legacy-panel' \
  'PANEL_PASSWORD=fixture-panel' > "$PNA_LEGACY_HANDOFF_DIR/HANDOFF-SECRETS.txt"

# shellcheck source=/dev/null
handoff_init
credential_store_seed_from_handoffs
handoff_begin_run
handoff_login_form_complete
test "$(credential_value_from_file "$HANDOFF_FILE" VPS_LOGIN_USER)" = legacy-root
test "$(credential_value_from_file "$HANDOFF_FILE" PANEL_PASSWORD)" = fixture-panel

credential_store_set PANEL_PASSWORD replacement
handoff_delete PANEL_PASSWORD
rm -f -- "$PNA_LEGACY_HANDOFF_DIR/HANDOFF-SECRETS.txt"
if handoff_login_form_complete >/dev/null 2>&1; then
  echo 'incomplete login handoff was accepted' >&2
  exit 1
fi
handoff_restore_stored_login_credentials
handoff_login_form_complete

if credential_store_set PANEL_PASSWORD UNKNOWN_NOT_RECOVERABLE >/dev/null 2>&1; then
  echo 'placeholder password entered the current-login store' >&2
  exit 1
fi

echo COMPLETE_LOGIN_HANDOFF_TEST_OK
