#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REBIND="$ROOT/runbook/proxy-node-assistant-v1.0.0/linux/27-ip-rebind.sh"
REALITY="$ROOT/runbook/proxy-node-assistant-v1.0.0/linux/04a-reality-api.sh"

bash -n "$REBIND" "$REALITY"
grep -Fq 'PUBLIC_FILE="${PNA_REBIND_PUBLIC_FILE:-/etc/proxy-runbook/public.env}"' "$REBIND"
grep -Fq 'normalize-all-shares' "$REBIND"
grep -Fq '04e-export-reality-handoff.sh' "$REBIND"
grep -Fq '23-ss2022-tcp.sh" handoff' "$REBIND"
grep -Fq 'IP_REBIND_BLOCKED_POST_DNS' "$REBIND"
grep -Fq 'MANAGED_OLD_IP_REMAINS' "$REBIND"
grep -Fq 'REALITY_ALL_SHARE_ADDRESSES_NORMALIZED' "$REALITY"
if grep -Fq '|| printf direct-reality' "$REBIND" || grep -Fq '|| printf ACTIVE_DIRECT' "$REBIND"; then
  echo 'unsafe direct-mode fallback remains in ip-rebind script' >&2
  exit 1
fi
echo IP_REBIND_STATIC_OK
