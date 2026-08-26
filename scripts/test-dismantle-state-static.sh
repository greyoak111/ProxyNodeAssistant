#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/runbook/text-node-assistant-v0.9.5/linux/22-dismantle-managed-node.sh"
GO="$ROOT/operations.go"

grep -q 'LEGAL_ACTIONS=PROXY_ONLY,FULL_BASELINE' "$SCRIPT"
grep -q 'LEGAL_ACTIONS=REMAINING_DRIVE' "$SCRIPT"
grep -q 'LEGAL_ACTIONS=RECOVER_IN_MENU_1' "$SCRIPT"
grep -q 'REMOVAL_STATUS=%s' "$SCRIPT"
grep -q 'PROXY_REMOVED_DRIVE_RETAINED' "$SCRIPT"
grep -q 'DRIVE_REGISTRATION_READY=0' "$SCRIPT"
grep -q -- '--execute-proxy-only' "$SCRIPT"
grep -q -- '--execute-remaining-drive' "$SCRIPT"
grep -q 'Shared packages are deliberately retained by default' "$SCRIPT"
grep -q 'verifyDismantleRescueContents' "$GO"
grep -q 'This state forbids drive-only removal\|此状态禁止单独拆网盘' "$GO"

echo DISMANTLE_STATE_STATIC_TEST_OK
