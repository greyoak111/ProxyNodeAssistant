#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SERVER="$ROOT/runbook/text-node-assistant-v0.9.5/linux/27-ip-rebind.sh"
WINDOWS="$ROOT/ip_rebind.go"

bash -n "$SERVER"
grep -q 'IP_REBIND_BLOCKED_POST_DNS' "$SERVER"
grep -q 'status|--status)' "$SERVER"
grep -q 'WAITING_FOR_CLOUDFLARE_MANUAL_ACTION' "$SERVER"
grep -q 'CLOUDFLARE_MUTATION=NONE' "$SERVER"
grep -q 'NEW_IP_EQUALS_OLD_IP' "$SERVER"
grep -q 'REMOTE_PUBLIC_IP_MISMATCH' "$SERVER"
grep -q 'JOINT_DOMAIN_MIGRATION_REQUIRES_CLOUDFLARE_PHASE' "$SERVER"
grep -q 'SNAPSHOT_PATH_INVALID' "$SERVER"
grep -q 'IP_REBIND_PENDING' "$ROOT/runbook/text-node-assistant-v0.9.5/linux/16-auto-diagnose.sh"
grep -q 'IP_REBIND_BLOCKED' "$ROOT/runbook/text-node-assistant-v0.9.5/linux/16-auto-diagnose.sh"
grep -q 'HOST_KEY_MISMATCH' "$WINDOWS"
grep -q 'LOCAL_KEY_RECORD_NOT_FOUND' "$WINDOWS"
grep -q 'PUBLICKEY_REJECTED' "$WINDOWS"
grep -q 'SSH_AUTH_KEY_ID_UNCHANGED=1' "$WINDOWS"
grep -q 'cloudflareDNSDashboardURL' "$WINDOWS"
! grep -Eq 'ssh-keygen[^\n]*-[Rr]' "$WINDOWS"
! grep -Eq 'Cloudflare[^\n]*(token|Token).*clipboard' "$WINDOWS"

echo IP_REBIND_STATIC_OK
