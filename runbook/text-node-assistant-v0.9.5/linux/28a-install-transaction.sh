#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

ACTION="${1:-status}"
OPERATION_ID="${2:-standalone}"
FENCING_TOKEN="${3:-0}"
STATE_ROOT=/var/lib/text-node-assistant/install-transaction-v1
CURRENT="$STATE_ROOT/current.env"
SNAPSHOT="$STATE_ROOT/snapshot"
HISTORY="$STATE_ROOT/history"
LOCK="$STATE_ROOT/lock"

paths=(
  /etc/x-ui
  /usr/local/x-ui
  /etc/systemd/system/x-ui.service
  /etc/systemd/system/x-ui.service.d
  /etc/nginx
  /etc/letsencrypt
  /etc/ufw
  /etc/fail2ban
  /etc/sysctl.conf
  /etc/sysctl.d
  /etc/apt/sources.list.d/cloudflare-client.list
  /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg
  /var/lib/cloudflare-warp
  /etc/systemd/system/nginx.service.d
  /etc/systemd/system/warp-svc.service
  /etc/systemd/system/text-node-assistant-zram.service
  /etc/systemd/system/text-node-assistant-copyparty.service
  /etc/systemd/system/text-node-assistant-security-firewall.service
  /etc/text-node-assistant
  /root/.config/text-node-assistant
  /opt/text-node-assistant/copyparty
  /var/lib/text-node-assistant/copyparty
  /usr/local/lib/text-node-assistant
  /etc/logrotate.d/text-node-assistant-security
  /var/www/cover
)
names=(
  etc-x-ui
  usr-local-x-ui
  x-ui-unit
  x-ui-dropin
  etc-nginx
  etc-letsencrypt
  etc-ufw
  etc-fail2ban
  etc-sysctl-conf
  etc-sysctl-d
  warp-source
  warp-keyring
  warp-state
  nginx-dropin
  warp-unit
  zram-unit
  drive-unit
  security-unit
  tna-etc
  tna-root-config
  copyparty-program
  copyparty-state
  tna-local-lib
  tna-logrotate
  cover-root
)
services=(x-ui nginx warp-svc fail2ban vnstat text-node-assistant-zram.service text-node-assistant-copyparty.service text-node-assistant-security-firewall.service)

die() { printf 'TNA_INSTALL_TRANSACTION_ERROR=%s\n' "$1" >&2; exit "${2:-1}"; }
value() { sed -n "s/^$1=//p" "$CURRENT" 2>/dev/null | sed -n '1p'; }
data_files() { [ -d /srv/text-node-assistant/drive-data ] && find /srv/text-node-assistant/drive-data -type f -printf . 2>/dev/null | wc -c || printf '0\n'; }
data_bytes() { [ -d /srv/text-node-assistant/drive-data ] && find /srv/text-node-assistant/drive-data -type f -printf '%s\n' 2>/dev/null | awk '{sum+=$1} END{printf "%.0f\n",sum+0}' || printf '0\n'; }

install -d -m 700 "$STATE_ROOT" "$HISTORY"
exec 9>"$LOCK"
flock -x 9

write_status() {
  local status="$1" tmp
  [ -s "$CURRENT" ] || return 1
  tmp="$CURRENT.tmp.$$"
  awk -F= -v status="$status" '$1!="TRANSACTION_STATUS" && $1!="UPDATED_AT" {print}' "$CURRENT" > "$tmp"
  printf 'TRANSACTION_STATUS=%s\nUPDATED_AT=%s\n' "$status" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$tmp"
  chmod 600 "$tmp"
  mv -f -- "$tmp" "$CURRENT"
}

print_status() {
  echo TNA_INSTALL_TRANSACTION_STATUS_BEGIN
  if [ ! -s "$CURRENT" ]; then
    echo TRANSACTION_STATUS=NONE
  else
    cat "$CURRENT"
  fi
  printf 'CURRENT_DRIVE_FILE_COUNT=%s\nCURRENT_DRIVE_DATA_BYTES=%s\n' "$(data_files)" "$(data_bytes)"
  echo TNA_INSTALL_TRANSACTION_STATUS_END
}

snapshot_path() {
  local source="$1" name="$2"
  if [ -e "$source" ] || [ -L "$source" ]; then
    printf 'present\n' > "$SNAPSHOT/$name.presence"
    cp -a -- "$source" "$SNAPSHOT/$name"
  else
    printf 'absent\n' > "$SNAPSHOT/$name.presence"
  fi
}

restore_path() {
  local target="$1" name="$2"
  [ -s "$SNAPSHOT/$name.presence" ] || return 1
  rm -rf -- "$target"
  if grep -Fqx present "$SNAPSHOT/$name.presence"; then
    mkdir -p -- "$(dirname "$target")"
    cp -a -- "$SNAPSHOT/$name" "$target"
  fi
}

record_service_states() {
  local service safe
  for service in "${services[@]}"; do
    safe="${service//[-.]/_}"
    if systemctl is-enabled --quiet "$service" 2>/dev/null; then echo 1 > "$SNAPSHOT/service-$safe.enabled"; else echo 0 > "$SNAPSHOT/service-$safe.enabled"; fi
    if systemctl is-active --quiet "$service" 2>/dev/null; then echo 1 > "$SNAPSHOT/service-$safe.active"; else echo 0 > "$SNAPSHOT/service-$safe.active"; fi
  done
}

restore_service_states() {
  local service safe failed=0
  systemctl daemon-reload || failed=1
  for service in "${services[@]}"; do
    safe="${service//[-.]/_}"
    if grep -Fqx 1 "$SNAPSHOT/service-$safe.enabled" 2>/dev/null; then systemctl enable "$service" >/dev/null 2>&1 || failed=1; else systemctl disable "$service" >/dev/null 2>&1 || true; fi
    if grep -Fqx 1 "$SNAPSHOT/service-$safe.active" 2>/dev/null; then systemctl start "$service" >/dev/null 2>&1 || failed=1; else systemctl stop "$service" >/dev/null 2>&1 || true; fi
  done
  return "$failed"
}

archive_receipt() {
  local outcome="$1" transaction stamp receipt
  transaction="$(value TRANSACTION_ID)"
  stamp="$(date -u +%Y%m%dT%H%M%SZ)"
  receipt="$HISTORY/${transaction:-unknown}-$stamp.env"
  { cat "$CURRENT"; printf 'FINAL_STATUS=%s\nFINISHED_AT=%s\n' "$outcome" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"; } > "$receipt.tmp.$$"
  chmod 600 "$receipt.tmp.$$"
  mv -f -- "$receipt.tmp.$$" "$receipt"
  printf '%s' "$receipt"
}

begin_transaction() {
  [ ! -s "$CURRENT" ] || die ACTIVE_TRANSACTION_EXISTS 80
  [[ "$OPERATION_ID" =~ ^(tna-op-[0-9a-f]{32}|standalone)$ ]] || die OPERATION_ID_INVALID 81
  [[ "$FENCING_TOKEN" =~ ^[0-9]+$ ]] || die FENCING_TOKEN_INVALID 81
  rm -rf -- "$SNAPSHOT"
  install -d -m 700 "$SNAPSHOT"
  local transaction tmp index path name drive_present=0
  transaction="tna-install-$(date -u +%Y%m%dT%H%M%SZ)-$(openssl rand -hex 6)"
  tmp="$CURRENT.tmp.$$"
  {
    echo TRANSACTION_SCHEMA_VERSION=1
    printf 'TRANSACTION_ID=%s\nOPERATION_ID=%s\nFENCING_TOKEN=%s\n' "$transaction" "$OPERATION_ID" "$FENCING_TOKEN"
    echo TRANSACTION_STATUS=PREPARING
    printf 'STARTED_AT=%s\nUPDATED_AT=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  } > "$tmp"
  chmod 600 "$tmp"
  mv -f -- "$tmp" "$CURRENT"
  for index in "${!paths[@]}"; do
    path="${paths[$index]}"; name="${names[$index]}"; snapshot_path "$path" "$name"
  done
  record_service_states
  [ ! -d /srv/text-node-assistant/drive-data ] || drive_present=1
  {
    printf 'DRIVE_DATA_PRESENT=%s\n' "$drive_present"
    printf 'DRIVE_FILE_COUNT=%s\nDRIVE_DATA_BYTES=%s\n' "$(data_files)" "$(data_bytes)"
  } > "$SNAPSHOT/drive-inventory.env"
  write_status ACTIVE
  printf 'TNA_INSTALL_TRANSACTION_BEGAN=1\nTRANSACTION_ID=%s\n' "$transaction"
}

verify_preserved_drive() {
  local present before_files before_bytes now_files now_bytes
  present="$(sed -n 's/^DRIVE_DATA_PRESENT=//p' "$SNAPSHOT/drive-inventory.env")"
  before_files="$(sed -n 's/^DRIVE_FILE_COUNT=//p' "$SNAPSHOT/drive-inventory.env")"
  before_bytes="$(sed -n 's/^DRIVE_DATA_BYTES=//p' "$SNAPSHOT/drive-inventory.env")"
  if [ "$present" = 1 ]; then
    [ -d /srv/text-node-assistant/drive-data ] || return 1
    now_files="$(data_files)"; now_bytes="$(data_bytes)"
    [ "$before_files" = "$now_files" ] && [ "$before_bytes" = "$now_bytes" ]
  else
    return 0
  fi
}

rollback_transaction() {
  [ -s "$CURRENT" ] || { echo TNA_INSTALL_TRANSACTION_ROLLBACK=NOT_NEEDED; return 0; }
  case "$(value TRANSACTION_STATUS)" in ACTIVE|ROLLING_BACK|ROLLBACK_FAILED) ;; PREPARING) rm -rf -- "$SNAPSHOT"; rm -f -- "$CURRENT"; echo TNA_INSTALL_TRANSACTION_ROLLBACK=PREPARE_ABORTED; return 0;; *) die TRANSACTION_NOT_ROLLBACKABLE 82;; esac
  [ -d "$SNAPSHOT" ] || die SNAPSHOT_MISSING 83
  write_status ROLLING_BACK
  local service index failed=0 receipt drive_present
  for service in "${services[@]}"; do systemctl stop "$service" >/dev/null 2>&1 || true; done
  for index in "${!paths[@]}"; do restore_path "${paths[$index]}" "${names[$index]}" || failed=1; done
  drive_present="$(sed -n 's/^DRIVE_DATA_PRESENT=//p' "$SNAPSHOT/drive-inventory.env")"
  if [ "$drive_present" = 0 ]; then
    rm -rf -- /srv/text-node-assistant/drive-data || failed=1
  else
    verify_preserved_drive || failed=1
  fi
  restore_service_states || failed=1
  sysctl --system >/dev/null 2>&1 || true
  if [ "$failed" -ne 0 ]; then
    write_status ROLLBACK_FAILED
    die ROLLBACK_INCOMPLETE 91
  fi
  write_status ROLLED_BACK
  receipt="$(archive_receipt ROLLED_BACK)"
  rm -rf -- "$SNAPSHOT"
  rm -f -- "$CURRENT"
  printf 'TNA_INSTALL_TRANSACTION_ROLLED_BACK=1\nTRANSACTION_RECEIPT=%s\n' "$receipt"
}

commit_transaction() {
  [ -s "$CURRENT" ] || die TRANSACTION_MISSING 84
  [ "$(value TRANSACTION_STATUS)" = ACTIVE ] || die TRANSACTION_NOT_ACTIVE 84
  verify_preserved_drive || die PREEXISTING_DRIVE_INVENTORY_CHANGED 92
  write_status COMMITTED
  local receipt
  receipt="$(archive_receipt COMMITTED)"
  rm -rf -- "$SNAPSHOT"
  rm -f -- "$CURRENT"
  printf 'TNA_INSTALL_TRANSACTION_COMMITTED=1\nTRANSACTION_RECEIPT=%s\n' "$receipt"
}

case "$ACTION" in
  status) print_status ;;
  begin) begin_transaction ;;
  rollback) rollback_transaction ;;
  commit) commit_transaction ;;
  *) die USAGE 2 ;;
esac
