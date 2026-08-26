#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ADAPTER="$ROOT/runbook/text-node-assistant-v0.9.5/linux/32-subscription-rewrite.py"
UNIT="$ROOT/runbook/text-node-assistant-v0.9.5/templates/systemd/text-node-assistant-subscription-proxy.service"
COVER="$ROOT/runbook/text-node-assistant-v0.9.5/linux/05c-optimize-cover-backend.sh"
SUB="$ROOT/runbook/text-node-assistant-v0.9.5/linux/05d-configure-subscription.sh"
DOCTOR="$ROOT/runbook/text-node-assistant-v0.9.5/linux/16-auto-diagnose.sh"

test -s "$ADAPTER"
test -s "$UNIT"
bash -n "$COVER"
bash -n "$SUB"
bash -n "$DOCTOR"

if command -v python3 >/dev/null 2>&1; then
  PYTHON_FILE="$ADAPTER"
  command -v cygpath >/dev/null 2>&1 && PYTHON_FILE="$(cygpath -w "$ADAPTER")"
  python3 -c 'import pathlib,sys; p=pathlib.Path(sys.argv[1]); compile(p.read_text(encoding="utf-8"), str(p), "exec")' "$PYTHON_FILE"
elif command -v python >/dev/null 2>&1; then
  PYTHON_FILE="$ADAPTER"
  command -v cygpath >/dev/null 2>&1 && PYTHON_FILE="$(cygpath -w "$ADAPTER")"
  python -c 'import pathlib,sys; p=pathlib.Path(sys.argv[1]); compile(p.read_text(encoding="utf-8"), str(p), "exec")' "$PYTHON_FILE"
else
  echo 'Python is required to validate the subscription adapter.' >&2
  exit 1
fi

grep -q 'TNA-Subscription-Rewrite' "$ADAPTER"
grep -q 'security.*tls' "$ADAPTER"
grep -q 'sni' "$ADAPTER"
grep -q 'host' "$ADAPTER"
grep -q 'mode.*packet-up' "$ADAPTER"
grep -q 'SUB_PROXY_PORT=2097' "$COVER"
grep -q 'text-node-assistant-subscription-proxy.service' "$COVER"
grep -Fq 'proxy_pass http://127.0.0.1:${SUB_PROXY_PORT};' "$COVER"
grep -q 'SUB_PROXY_PORT=2097' "$SUB"
grep -q 'SUB_PROXY_LISTEN' "$DOCTOR"
grep -q 'proxy_pass http://127.0.0.1:2097;' "$DOCTOR"
if grep -q 'proxy_pass http://127.0.0.1:2096;' "$COVER" "$SUB" "$DOCTOR"; then
  echo 'Nginx must not expose the raw 3x-ui subscription exporter.' >&2
  exit 1
fi
grep -q 'RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX' "$UNIT"
grep -q 'StandardOutput=null' "$UNIT"

echo 'SUBSCRIPTION_XHTTP_STATIC_TEST_OK'
