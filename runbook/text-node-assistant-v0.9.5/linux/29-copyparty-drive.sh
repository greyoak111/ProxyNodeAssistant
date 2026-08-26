#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/linux/lib-third-party.sh"
. "$ROOT/linux/lib-drive.sh"

tna_drive_admin_install() {
  local username="${1:-}" requested="${2:-auto}" data_root port minimum_free adaptive quota salt hash
  local lifecycle ready admin_line account_id space_id created
  tna_drive_valid_admin_username "$username" || { echo 'TNA_DRIVE_ERROR=ADMIN_USERNAME_INVALID' >&2; return 149; }
  tna_drive_read_password
  tna_drive_prepare_base "$ROOT"
  tna_drive_lock
  data_root="$(tna_drive_data_root)"
  read -r minimum_free adaptive < <(tna_drive_disk_budget "$data_root")
  quota="$(tna_drive_resolve_quota "$requested" "$adaptive")"
  port="$(tna_drive_choose_port)"
  salt="$(tna_drive_state_value DRIVE_PASSWORD_SALT || true)"
  [ -n "$salt" ] || salt="$(tna_drive_random_hex 24)"
  hash="$(tna_drive_password_hash "$username" "$TNA_DRIVE_PASSWORD" "$salt")"
  lifecycle="$(tna_drive_state_value NODE_LIFECYCLE_STATE || printf DRIVE_ONLY_UNFINALIZED)"
  ready="$(tna_drive_state_value DRIVE_REGISTRATION_READY || printf 0)"

  tna_drive_txn_begin
  admin_line="$(tna_drive_registry_admin_line || true)"
  if [ -n "$admin_line" ]; then
    IFS=$'\t' read -r account_id space_id _ _ _ _ _ created <<<"$admin_line"
    awk -F '\t' '$3!="admin" {print}' "$TNA_DRIVE_REGISTRY_FILE" > "$TNA_DRIVE_REGISTRY_FILE.next"
  else
    account_id="tna-account-$(tna_drive_random_hex 16)"
    space_id="tna-space-$(tna_drive_random_hex 16)"
    created="$(date -Is)"
    : > "$TNA_DRIVE_REGISTRY_FILE.next"
  fi
  printf '%s\t%s\tadmin\tactive\t%s\t%s\t%s\t%s\n' "$account_id" "$space_id" "$username" "$hash" "$quota" "$created" >> "$TNA_DRIVE_REGISTRY_FILE.next"
  chmod 0600 "$TNA_DRIVE_REGISTRY_FILE.next"
  chown root:root "$TNA_DRIVE_REGISTRY_FILE.next"
  mv -f -- "$TNA_DRIVE_REGISTRY_FILE.next" "$TNA_DRIVE_REGISTRY_FILE"
  if ! tna_drive_apply "$ROOT" "$data_root" "$port" "$salt" "$minimum_free" "$lifecycle" "$ready" || \
     ! tna_drive_verify_crud "$port" "$username" "$TNA_DRIVE_PASSWORD" /files/admin; then
    tna_drive_txn_rollback
    unset TNA_DRIVE_PASSWORD
    return 148
  fi
  tna_drive_txn_commit
  unset TNA_DRIVE_PASSWORD
  printf '__TNA_DRIVE_RESULT_BEGIN__\n'
  printf 'PRIVATE_DRIVE_STATUS=READY\nCOPYPARTY_LISTEN=127.0.0.1:%s\nCOPYPARTY_LOOPBACK_PORT=%s\n' "$port" "$port"
  printf 'DRIVE_ADMIN_USERNAME=%s\nDRIVE_ADMIN_PATH=/files/admin/\nPRIVATE_DRIVE_QUOTA_GIB=%s\n' "$username" "$quota"
  printf 'DRIVE_ACCOUNT_LIMIT=%s\nPRIVATE_DRIVE_PUBLIC_ACCESS=BLOCKED\n' "$TNA_DRIVE_ACCOUNT_LIMIT"
  printf '__TNA_DRIVE_RESULT_END__\n'
}

tna_drive_finalize() {
  local lifecycle="${1:-}" data_root port salt minimum_free
  tna_drive_lifecycle_allows_registration "$lifecycle" || {
    [ "$lifecycle" = PROXY_REMOVED_DRIVE_RETAINED ] || { echo 'TNA_DRIVE_ERROR=LIFECYCLE_INVALID' >&2; return 149; }
  }
  tna_drive_prepare_base "$ROOT"
  tna_drive_lock
  data_root="$(tna_drive_data_root)"
  port="$(tna_drive_state_value COPYPARTY_LOOPBACK_PORT)"
  salt="$(tna_drive_state_value DRIVE_PASSWORD_SALT)"
  minimum_free="$(tna_drive_state_value PRIVATE_DRIVE_MIN_FREE_BYTES)"
  tna_drive_wait_ready "$port"
  tna_drive_validate_registry
  local ready=0
  tna_drive_lifecycle_allows_registration "$lifecycle" && ready=1
  tna_drive_txn_begin
  if ! tna_drive_write_state "$data_root" "$port" "$salt" "$minimum_free" "$lifecycle" "$ready"; then
    tna_drive_txn_rollback
    return 148
  fi
  tna_drive_txn_commit
  printf 'TNA_DRIVE_FINALIZED=1\nNODE_LIFECYCLE_STATE=%s\nDRIVE_REGISTRATION_READY=%s\n' "$lifecycle" "$ready"
}

tna_drive_show_status() {
  local service=inactive listener=0 port state mode version data_root lifecycle ready admin_line admin_user ordinary used=0
  port="$(tna_drive_state_value COPYPARTY_LOOPBACK_PORT || printf 0)"
  systemctl is-active --quiet "$TNA_DRIVE_SERVICE" && service=active
  if [[ "$port" =~ ^39[0-9]{3}$ ]] && ss -H -lntp 2>/dev/null | awk -v p="127.0.0.1:$port" '$4==p {found=1} END{exit found ? 0 : 1}'; then listener=1; fi
  state="$(tna_drive_state_value PRIVATE_DRIVE_STATUS || printf disabled)"
  mode="$(tna_drive_state_value PRIVATE_DRIVE_MODE || printf disabled)"
  version="$(tna_drive_state_value COPYPARTY_VERSION || printf unknown)"
  data_root="$(tna_drive_data_root)"
  lifecycle="$(tna_drive_state_value NODE_LIFECYCLE_STATE || printf UNMANAGED)"
  ready="$(tna_drive_state_value DRIVE_REGISTRATION_READY || printf 0)"
  admin_line="$(tna_drive_registry_admin_line || true)"
  admin_user=unknown
  [ -z "$admin_line" ] || IFS=$'\t' read -r _ _ _ _ admin_user _ _ _ <<<"$admin_line"
  ordinary="$(tna_drive_active_ordinary_count)"
  [ -d "$data_root" ] && used="$(du -sb "$data_root" 2>/dev/null | awk '{print $1}' || printf 0)"
  printf '__TNA_DRIVE_STATUS_BEGIN__\n'
  printf 'PRIVATE_DRIVE_MODE=%s\nPRIVATE_DRIVE_STATUS=%s\nCOPYPARTY_SERVICE=%s\nCOPYPARTY_LOOPBACK_LISTENER=%s\n' "$mode" "$state" "$service" "$listener"
  printf 'COPYPARTY_VERSION=%s\nCOPYPARTY_LOOPBACK_PORT=%s\nCOPYPARTY_LISTEN=127.0.0.1:%s\n' "$version" "$port" "$port"
  printf 'DRIVE_ADMIN_USERNAME=%s\nDRIVE_ADMIN_PATH=/files/admin/\nDRIVE_ORDINARY_ACCOUNT_COUNT=%s\nDRIVE_ACCOUNT_LIMIT=%s\n' "$admin_user" "$ordinary" "$TNA_DRIVE_ACCOUNT_LIMIT"
  printf 'DRIVE_DATA_ROOT=%s\nPRIVATE_DRIVE_USED_BYTES=%s\nNODE_LIFECYCLE_STATE=%s\nDRIVE_REGISTRATION_READY=%s\n' "$data_root" "$used" "$lifecycle" "$ready"
  printf 'PRIVATE_DRIVE_PUBLIC_ACCESS=BLOCKED\n__TNA_DRIVE_STATUS_END__\n'
}

tna_drive_uninstall_preserve() {
  tna_drive_require_root
  tna_drive_lock
  systemctl disable --now "$TNA_DRIVE_SERVICE" >/dev/null 2>&1 || true
  if [ -f "$TNA_DRIVE_UNIT_FILE" ] && grep -qF '# TNA_MANAGED_COPYPARTY_SYSTEMD_V095' "$TNA_DRIVE_UNIT_FILE"; then rm -f -- "$TNA_DRIVE_UNIT_FILE"; fi
  if [ -f "$TNA_DRIVE_CONFIG_FILE" ] && grep -qF '# TNA_MANAGED_COPYPARTY_V095' "$TNA_DRIVE_CONFIG_FILE"; then rm -f -- "$TNA_DRIVE_CONFIG_FILE"; fi
  rm -rf -- "$TNA_DRIVE_PROGRAM_DIR"
  systemctl daemon-reload
  if [ -f "$TNA_DRIVE_STATE_FILE" ]; then
    sed 's/^PRIVATE_DRIVE_STATUS=.*/PRIVATE_DRIVE_STATUS=DISABLED_DATA_PRESERVED/; s/^DRIVE_REGISTRATION_READY=.*/DRIVE_REGISTRATION_READY=0/' "$TNA_DRIVE_STATE_FILE" > "$TNA_DRIVE_STATE_FILE.next"
    chmod 0600 "$TNA_DRIVE_STATE_FILE.next" && mv -f -- "$TNA_DRIVE_STATE_FILE.next" "$TNA_DRIVE_STATE_FILE"
  fi
  echo 'TNA_DRIVE_UNINSTALLED_DATA_PRESERVED'
}

tna_drive_purge() {
  [ "${1:-}" = RESTORE-NATIVE-BASELINE ] || { echo 'TNA_DRIVE_ERROR=PURGE_CONFIRMATION_REQUIRED' >&2; return 150; }
  local data_root
  data_root="$(tna_drive_data_root)"
  case "$data_root" in "$TNA_DRIVE_NEW_DATA_ROOT"|"$TNA_DRIVE_LEGACY_DATA_ROOT") ;; *) return 150;; esac
  tna_drive_uninstall_preserve
  rm -rf -- "$data_root" "$TNA_DRIVE_RUNTIME_DIR" "$TNA_DRIVE_LOG_DIR"
  rm -f -- "$TNA_DRIVE_STATE_FILE" "$TNA_DRIVE_REGISTRY_FILE"
  echo 'TNA_DRIVE_PURGED_FOR_NATIVE_BASELINE'
}

case "${1:-}" in
  install-admin|rotate-admin) [ "$#" -eq 3 ] || exit 2; tna_drive_admin_install "$2" "$3" ;;
  finalize-install) [ "$#" -eq 2 ] || exit 2; tna_drive_finalize "$2" ;;
  verify-admin)
    [ "$#" -eq 2 ] || exit 2; tna_drive_read_password
    port="$(tna_drive_state_value COPYPARTY_LOOPBACK_PORT)"
    tna_drive_wait_ready "$port" && tna_drive_verify_crud "$port" "$2" "$TNA_DRIVE_PASSWORD" /files/admin
    unset TNA_DRIVE_PASSWORD
    ;;
  status) [ "$#" -eq 1 ] || exit 2; tna_drive_show_status ;;
  uninstall-preserve) [ "$#" -eq 1 ] || exit 2; tna_drive_uninstall_preserve ;;
  purge) [ "$#" -eq 2 ] || exit 2; tna_drive_purge "$2" ;;
  *) echo 'usage: 29-copyparty-drive.sh install-admin USER auto|GIB | rotate-admin USER auto|GIB | finalize-install LIFECYCLE | verify-admin USER | status | uninstall-preserve | purge RESTORE-NATIVE-BASELINE' >&2; exit 2 ;;
esac
