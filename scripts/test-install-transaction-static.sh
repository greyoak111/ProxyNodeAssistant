#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT="runbook/text-node-assistant-v0.9.5/linux/28a-install-transaction.sh"
GO_FILE="install_transaction.go"
OPERATIONS="operations.go"

bash -n "$SCRIPT"
grep -Fq 'TRANSACTION_STATUS=PREPARING' "$SCRIPT"
grep -Fq 'write_status ACTIVE' "$SCRIPT"
grep -Fq 'write_status ROLLING_BACK' "$SCRIPT"
grep -Fq 'TNA_INSTALL_TRANSACTION_ROLLED_BACK=1' "$SCRIPT"
grep -Fq 'TNA_INSTALL_TRANSACTION_COMMITTED=1' "$SCRIPT"
grep -Fq 'verify_preserved_drive' "$SCRIPT"
grep -Fq 'rm -rf -- /srv/text-node-assistant/drive-data' "$SCRIPT"
! grep -Fq 'rm -rf -- /srv ' "$SCRIPT"
! grep -Fq 'rm -rf -- / ' "$SCRIPT"
! grep -Fq 'rm -rf -- "$STATE_ROOT"' "$SCRIPT"
grep -Fq 'recoverInterruptedInstallTransaction(c)' "$OPERATIONS"
grep -Fq 'beginInstallTransaction(c)' "$OPERATIONS"
grep -Fq 'commitInstallTransaction(c, transactionID)' "$OPERATIONS"
grep -Fq 'rollbackInstallTransaction(c, transactionID)' "$OPERATIONS"
grep -Fq 'refusing to roll back another install transaction' "$GO_FILE"

echo INSTALL_TRANSACTION_STATIC_OK
