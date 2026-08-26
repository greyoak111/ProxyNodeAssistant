#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IDENTITY="$ROOT/runbook/text-node-assistant-v0.9.5/linux/23-node-identity.sh"
DEVICE="$ROOT/runbook/text-node-assistant-v0.9.5/linux/26-device-admission.sh"

bash -n "$IDENTITY"
bash -n "$DEVICE"

grep -qF 'tna-device-' "$DEVICE"
grep -qF '^(tna|pna)-node-' "$DEVICE"
grep -qF 'base64.b32encode' "$DEVICE"
grep -qF "(?:tna|pna)-ed25519" "$DEVICE"
grep -qF "prefix+'-device-'" "$DEVICE"
grep -qF '^\(tna|pna\)-device-' "$DEVICE" || grep -qF '^(tna|pna)-device-' "$DEVICE"
grep -qF 'openssl pkeyutl -verify' "$DEVICE"
grep -qF 'TNA-DEVICE-ENROLL-V2' "$DEVICE"
grep -qF 'consumePolicy:"successful-bind"' "$DEVICE"
grep -qF 'STATUS=pending-verification' "$DEVICE"
grep -qF 'NONCE_CONSUMED=0' "$DEVICE"
grep -qF 'claim-forced' "$DEVICE"
grep -qF 'NONCE_CONSUMED=1' "$DEVICE"
grep -qF 'SSH_PUBLIC_KEY=' "$DEVICE"
grep -qF 'pending-verification' "$DEVICE"
grep -qF 'NONCE_INVALID_OR_USED' "$DEVICE"
grep -qF 'LAST_CONTROLLER_PROTECTED' "$DEVICE"
grep -qF 'TNA_DEVICE_TRANSACTION_ROLLED_BACK=1' "$DEVICE"
grep -qF 'TNA_DEVICE_REVOCATION_PARTIAL=1' "$DEVICE"
grep -qF 'trap '\''transaction_exit "$?"'\'' EXIT' "$DEVICE"
grep -qF 'CDN_MTLS_DEVICE=EXPERIMENTAL_BLOCKED' "$DEVICE"
grep -qF 'WIREGUARD_DEVICE_LOCK=EXPERIMENTAL_BLOCKED' "$DEVICE"

if grep -Eq 'DEVICE_IDENTITY_PRIVATE|PRIVATE_KEY=' "$DEVICE"; then
  echo 'device protocol must not accept or print a device private key' >&2
  exit 1
fi

echo DEVICE_ADMISSION_STATIC_TEST_OK
