#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IDENTITY="$ROOT/runbook/proxy-runbook-v0.9.5/linux/23-node-identity.sh"
DEVICE="$ROOT/runbook/proxy-runbook-v0.9.5/linux/26-device-admission.sh"

bash -n "$IDENTITY"
bash -n "$DEVICE"

grep -qF 'pna-device-' "$DEVICE"
grep -qF 'base64.b32encode' "$DEVICE"
grep -qF 'openssl pkeyutl -verify' "$DEVICE"
grep -qF 'PNA-DEVICE-ENROLL-V1' "$DEVICE"
grep -qF 'NONCE_EXPIRED_OR_USED' "$DEVICE"
grep -qF 'LAST_CONTROLLER_PROTECTED' "$DEVICE"
grep -qF 'PNA_DEVICE_TRANSACTION_ROLLED_BACK=1' "$DEVICE"
grep -qF 'PNA_DEVICE_REVOCATION_PARTIAL=1' "$DEVICE"
grep -qF 'trap '\''transaction_exit "$?"'\'' EXIT' "$DEVICE"
grep -qF 'CDN_MTLS_DEVICE=EXPERIMENTAL_BLOCKED' "$DEVICE"
grep -qF 'WIREGUARD_DEVICE_LOCK=EXPERIMENTAL_BLOCKED' "$DEVICE"

if grep -Eq 'DEVICE_IDENTITY_PRIVATE|PRIVATE_KEY=' "$DEVICE"; then
  echo 'device protocol must not accept or print a device private key' >&2
  exit 1
fi

echo DEVICE_ADMISSION_STATIC_TEST_OK
