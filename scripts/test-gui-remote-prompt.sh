#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ROOT/runbook/proxy-runbook-v0.9.5/linux/lib-gui-prompt.sh"
ERR="$(mktemp)"
trap 'rm -f "$ERR"' EXIT

ANSWER="$(printf 'y\n' | PROXY_RUNBOOK_GUI_MODE=1 bash -c '
  . "$1"
  value="$(proxy_runbook_read_answer "Remote 24443 verification [Y/n]")"
  printf "%s" "$value"
' _ "$LIB" 2>"$ERR")"
[ "$ANSWER" = "y" ]

FRAME="$(sed -n '1p' "$ERR")"
case "$FRAME" in PNA_GUI_PROMPT_B64=*) ;; *) echo "missing GUI prompt frame" >&2; exit 1;; esac
PAYLOAD="${FRAME#PNA_GUI_PROMPT_B64=}"
DECODED="$(printf '%s' "$PAYLOAD" | base64 -d)"
[ "$DECODED" = "Remote 24443 verification [Y/n]" ]

if PROXY_RUNBOOK_GUI_MODE=1 bash -c '. "$1"; proxy_runbook_read_answer "EOF test"' _ "$LIB" </dev/null >/dev/null 2>/dev/null; then
  echo "closed GUI input was accepted" >&2
  exit 1
fi

echo GUI_REMOTE_PROMPT_PROTOCOL_OK
