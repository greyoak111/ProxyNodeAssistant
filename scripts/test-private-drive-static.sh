#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DRIVE="$ROOT/runbook/proxy-runbook-v0.9.5/linux/29-copyparty-drive.sh"
LIB="$ROOT/runbook/proxy-runbook-v0.9.5/linux/lib-third-party.sh"
CONF="$ROOT/runbook/proxy-runbook-v0.9.5/templates/copyparty/copyparty.conf.in"
UNIT="$ROOT/runbook/proxy-runbook-v0.9.5/templates/systemd/proxy-node-assistant-copyparty.service"
NGINX="$ROOT/runbook/proxy-runbook-v0.9.5/linux/31-copyparty-nginx.sh"
WIN="$ROOT/private_drive.go"
ANDROID="$ROOT/android/app/src/main/java/com/proxynodeassistant/android/remote/WorkflowRunner.kt"

for file in "$DRIVE" "$LIB" "$CONF" "$UNIT" "$NGINX" "$WIN" "$ANDROID"; do
  [ -s "$file" ] || { echo "missing private-drive component: $file" >&2; exit 1; }
done

grep -qF 'COPYPARTY_SFX_SHA256' "$LIB"
grep -qF 'COPYPARTY_SFX_SIZE' "$LIB"
grep -qF 'pna_sha256_check' "$LIB"
grep -qE '^[[:space:]]+i:[[:space:]]+127\.0\.0\.1$' "$CONF"
grep -qE '^[[:space:]]+p:[[:space:]]+3923$' "$CONF"
grep -qF '127.0.0.1:3923' "$DRIVE"
grep -qF 'PRIVATE_DRIVE_PUBLIC_ACCESS=BLOCKED' "$DRIVE"
grep -qF "LC_ALL=C grep -qE '^[ -~]{14,128}$'" "$DRIVE"
grep -qF 'PasswordStdinMissing' "$ANDROID" || grep -qF 'stdinBytes' "$ANDROID"
grep -qF 'rootCaptureWithInput' "$WIN"
grep -qF 'uninstall-preserve' "$DRIVE"
grep -qF 'PURGE-DATA' "$DRIVE"
grep -qF 'PNA_DRIVE_ERROR=TRANSACTION_ROLLED_BACK' "$DRIVE"
grep -qF 'rollback_config_and_state' "$DRIVE"
grep -qF '# PNA_MANAGED_COPYPARTY_SYSTEMD_V095' "$UNIT"
grep -qF '127.0.0.3' "$NGINX"
grep -qF 'PUBLIC_IP_PLACEHOLDER' "$NGINX"

if grep -Eq '(^|[[:space:]])listen[[:space:]]+0\.0\.0\.0:3923' "$CONF"; then
  echo 'copyparty config exposes its origin publicly' >&2
  exit 1
fi
if grep -Eq '(password|passwd|secret)[[:space:]]*=' "$CONF"; then
  echo 'copyparty template contains a plaintext secret assignment' >&2
  exit 1
fi
grep -qE '^COPYPARTY_SFX_URL=.*\/v1\.20\.21\/copyparty-sfx\.py' \
  "$ROOT/runbook/proxy-runbook-v0.9.5/THIRD_PARTY_LOCK.env"

echo 'PRIVATE_DRIVE_STATIC_TEST_OK'
