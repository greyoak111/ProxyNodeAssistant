#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DRIVE="$ROOT/runbook/text-node-assistant-v0.9.5/linux/29-copyparty-drive.sh"
DRIVE_LIB="$ROOT/runbook/text-node-assistant-v0.9.5/linux/lib-drive.sh"
ACCOUNT="$ROOT/runbook/text-node-assistant-v0.9.5/linux/30-copyparty-account.sh"
LIB="$ROOT/runbook/text-node-assistant-v0.9.5/linux/lib-third-party.sh"
CONF="$ROOT/runbook/text-node-assistant-v0.9.5/templates/copyparty/copyparty.conf.in"
UNIT="$ROOT/runbook/text-node-assistant-v0.9.5/templates/systemd/text-node-assistant-copyparty.service"
NGINX="$ROOT/runbook/text-node-assistant-v0.9.5/linux/31-copyparty-nginx.sh"
WIN="$ROOT/private_drive.go"
ANDROID="$ROOT/android/app/src/main/java/com/proxynodeassistant/android/remote/WorkflowRunner.kt"

for file in "$DRIVE" "$DRIVE_LIB" "$ACCOUNT" "$LIB" "$CONF" "$UNIT" "$NGINX" "$WIN" "$ANDROID"; do
  [ -s "$file" ] || { echo "missing private-drive component: $file" >&2; exit 1; }
done

grep -qF 'COPYPARTY_SFX_SHA256' "$LIB"
grep -qF 'COPYPARTY_SFX_SIZE' "$LIB"
grep -qF 'tna_sha256_check' "$LIB"
grep -qE '^[[:space:]]+i:[[:space:]]+127\.0\.0\.1$' "$CONF"
grep -qE '^[[:space:]]+p:[[:space:]]+@LOOPBACK_PORT@$' "$CONF"
grep -qF 'seq 39000 39999' "$DRIVE_LIB"
grep -qF 'PRIVATE_DRIVE_PUBLIC_ACCESS=BLOCKED' "$DRIVE"
grep -qF "LC_ALL=C grep -qE '^[ -~]{14,128}$'" "$DRIVE_LIB"
grep -qF 'PasswordStdinMissing' "$ANDROID" || grep -qF 'stdinBytes' "$ANDROID"
grep -qF 'rootCaptureWithInput' "$WIN"
grep -qF 'uninstall-preserve' "$DRIVE"
grep -qF 'RESTORE-NATIVE-BASELINE' "$DRIVE"
grep -qF 'TNA_DRIVE_ERROR=TRANSACTION_ROLLED_BACK' "$DRIVE_LIB"
grep -qF 'tna_drive_txn_rollback' "$DRIVE_LIB"
grep -qF 'TNA_DRIVE_CRUD_STEP_FAILED=' "$DRIVE_LIB"
grep -qF -- '--usernames --ah-alg scrypt --ah-salt "$salt" --ah-gen -' "$DRIVE_LIB"
grep -qF 'req("POST",name+"?delete"' "$DRIVE_LIB"
if grep -qF 'req("DELETE",name' "$DRIVE_LIB"; then
  echo 'drive verifier uses unsupported HTTP DELETE instead of POST ?delete' >&2
  exit 1
fi
grep -qF 'TNA_DRIVE_ACCOUNT_LIMIT=2' "$DRIVE_LIB"
grep -qF 'TNA_DRIVE_LEGACY_DATA_ROOT' "$DRIVE_LIB"
grep -qF "install -d -o root -g root -m 0711 \"\$state_root\"" "$DRIVE_LIB"
grep -qF "stat -c '%U:%G:%a'" "$DRIVE_LIB"
if grep -qF 'install -d -o root -g root -m 0700 "$(dirname "$TNA_DRIVE_LOCK_FILE")"' "$DRIVE_LIB"; then
  echo 'drive state root blocks the copyparty service working directory' >&2
  exit 1
fi
grep -qF 'change-password' "$ACCOUNT"
grep -qF 'TNA_DRIVE_ERROR=DRIVE_ACCOUNT_LIMIT_REACHED current=' "$ACCOUNT"
grep -qF 'tna_drive_txn_exit' "$DRIVE_LIB"
grep -qF '# TNA_MANAGED_COPYPARTY_SYSTEMD_V095' "$UNIT"
grep -qF 'ReadWritePaths=@DATA_ROOT@' "$UNIT"
grep -qF ' -i 127.0.0.1 -p @LOOPBACK_PORT@ --http-only --no-crt' "$UNIT"
grep -qF 'RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6 AF_NETLINK' "$UNIT"
grep -qF 'tna_drive_render_unit "$root" "$data_root" "$port"' "$DRIVE_LIB"
grep -qF 'local account_status account_username account_hash account_space_id account_role account_quota' "$DRIVE_LIB"
if grep -qF 'read -r _ space_id role status username _ quota _' "$DRIVE_LIB"; then
  echo 'copyparty renderer leaks loop variables into the install caller scope' >&2
  exit 1
fi
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
  "$ROOT/runbook/text-node-assistant-v0.9.5/THIRD_PARTY_LOCK.env"

echo 'PRIVATE_DRIVE_STATIC_TEST_OK'
