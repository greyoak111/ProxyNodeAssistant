#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIAG="$ROOT/runbook/proxy-runbook-v0.9.5/linux/16-auto-diagnose.sh"

# Keep this regression test offline. The diagnostic must still return a
# complete protocol block even when its public-IP probe cannot use the network.
curl() { return 1; }
export -f curl

OUTPUT="$(bash "$DIAG" --protocol-v1)"
grep -qx '__PNA_DIAG_V1_BEGIN__' <<<"$OUTPUT"
grep -qx '__PNA_DIAG_V1_END__' <<<"$OUTPUT"
grep -Eq '^(PASS|ISSUE)[[:space:]]' <<<"$OUTPUT"

if grep -qi 'jq missing' <<<"$OUTPUT"; then
  echo "diagnosis still depends on jq" >&2
  exit 1
fi

echo "DIAG_PROTOCOL_TEST_OK"
