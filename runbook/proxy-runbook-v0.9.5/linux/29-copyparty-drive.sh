#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/linux/lib-third-party.sh"

CONFIG_DIR=/etc/proxy-node-assistant
CONFIG_FILE="$CONFIG_DIR/copyparty.conf"
STATE_FILE=/etc/proxy-runbook/private-drive.env
PROGRAM_DIR=/opt/proxy-node-assistant/copyparty
PROGRAM_FILE="$PROGRAM_DIR/copyparty-sfx.py"
DATA_DIR=/srv/proxy-node-assistant/drive-data
RUNTIME_DIR=/var/lib/proxy-node-assistant/copyparty
LOG_DIR=/var/log/proxy-node-assistant/copyparty
UNIT_FILE=/etc/systemd/system/proxy-node-assistant-copyparty.service
SERVICE=proxy-node-assistant-copyparty.service
PNA_DRIVE_CONFIG_BACKUP=''

[ "$(id -u)" -eq 0 ] || { echo 'PNA_DRIVE_ERROR=ROOT_REQUIRED' >&2; exit 141; }
pna_load_third_party_lock "$ROOT" || { echo 'PNA_DRIVE_ERROR=THIRD_PARTY_LOCK_INVALID' >&2; exit 141; }

valid_username() { [[ "${1:-}" =~ ^[A-Za-z][A-Za-z0-9._-]{2,31}$ ]]; }
valid_quota() { case "${1:-}" in 2|3) return 0;; *) return 1;; esac; }

state_value() {
  local key="${1:?key required}" line
  [ -r "$STATE_FILE" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in "${key}="*) printf '%s\n' "${line#*=}"; return 0;; esac
  done < "$STATE_FILE"
  return 1
}

disk_budget() {
  local total available floor30 floor6 floor
  read -r total available < <(df -B1 --output=size,avail "$DATA_DIR" 2>/dev/null | awk 'NR==2 {print $1, $2}')
  case "$total:$available" in *[!0-9:]*|:*) echo 'PNA_DRIVE_ERROR=DISK_PROBE_FAILED' >&2; return 142;; esac
  floor6=$((6 * 1024 * 1024 * 1024))
  floor30=$(((total * 30 + 99) / 100))
  if [ "$floor30" -gt "$floor6" ]; then floor="$floor30"; else floor="$floor6"; fi
  [ "$available" -gt "$floor" ] || { echo 'PNA_DRIVE_ERROR=MIN_FREE_BUDGET_NOT_MET' >&2; return 143; }
  printf '%s\n' "$floor"
}

read_password() {
  local value=''
  IFS= read -r value || [ -n "$value" ] || { echo 'PNA_DRIVE_ERROR=PASSWORD_STDIN_MISSING' >&2; return 144; }
  [ -n "$value" ] || { echo 'PNA_DRIVE_ERROR=PASSWORD_EMPTY' >&2; return 144; }
  [[ "$value" != *$'\r'* && "$value" != *$'\n'* ]] || {
    echo 'PNA_DRIVE_ERROR=PASSWORD_CONTROL_CHARACTER' >&2; return 144;
  }
  LC_ALL=C grep -qE '^[ -~]{14,128}$' <<<"$value" || {
    echo 'PNA_DRIVE_ERROR=PASSWORD_NOT_PRINTABLE_ASCII_OR_LENGTH_INVALID' >&2; return 144;
  }
  PNA_DRIVE_PASSWORD="$value"
}

password_hash() {
  local username="${1:?username required}" password="${2:?password required}" salt="${3:?salt required}" output clean hash
  output="$(printf '%s\n' "${username}:${password}" | NO_COLOR=1 python3 "$PROGRAM_FILE" \
    --ah-alg scrypt --ah-salt "$salt" --ah-gen - 2>&1 || true)"
  clean="$(printf '%s\n' "$output" | sed -r 's/\x1B\[[0-9;]*[mK]//g')"
  hash="$(printf '%s\n' "$clean" | grep -E '^\+[A-Za-z0-9+/=_-]+$' | tail -1 || true)"
  [[ "$hash" =~ ^\+[A-Za-z0-9+/=_-]{20,200}$ ]] || { echo 'PNA_DRIVE_ERROR=PASSWORD_HASH_FAILED' >&2; return 145; }
  printf '%s\n' "$hash"
}

render_config() {
  local username="$1" hash="$2" salt="$3" quota="$4" minimum_free="$5" tmp
  tmp="$(mktemp "$CONFIG_DIR/.copyparty.conf.XXXXXX")"
  sed \
    -e "s|@ACCOUNT_USERNAME@|${username}|g" \
    -e "s|@ACCOUNT_HASH@|${hash}|g" \
    -e "s|@PASSWORD_SALT@|${salt}|g" \
    -e "s|@QUOTA_GIB@|${quota}|g" \
    -e "s|@MIN_FREE_BYTES@|${minimum_free}|g" \
    "$ROOT/templates/copyparty/copyparty.conf.in" > "$tmp"
  grep -qF '# PNA_MANAGED_COPYPARTY_V095' "$tmp" || { rm -f -- "$tmp"; return 146; }
  chmod 0640 "$tmp"
  chown root:copyparty "$tmp"
  if [ -f "$CONFIG_FILE" ]; then
    grep -qF '# PNA_MANAGED_COPYPARTY_V095' "$CONFIG_FILE" || {
      rm -f -- "$tmp"; echo 'PNA_DRIVE_ERROR=UNMANAGED_CONFIG_EXISTS' >&2; return 146;
    }
    PNA_DRIVE_CONFIG_BACKUP="$(mktemp "$CONFIG_DIR/.copyparty.rollback.XXXXXX")"
    cp -a -- "$CONFIG_FILE" "$PNA_DRIVE_CONFIG_BACKUP"
  fi
  mv -f -- "$tmp" "$CONFIG_FILE"
}

rollback_config_and_state() {
  local had_config="$1" state_backup="$2"
  systemctl stop "$SERVICE" >/dev/null 2>&1 || true
  if [ "$had_config" = 1 ] && [ -n "$PNA_DRIVE_CONFIG_BACKUP" ] && [ -f "$PNA_DRIVE_CONFIG_BACKUP" ]; then
    mv -f -- "$PNA_DRIVE_CONFIG_BACKUP" "$CONFIG_FILE"
  else
    rm -f -- "$CONFIG_FILE"
  fi
  if [ -n "$state_backup" ] && [ -f "$state_backup" ]; then
    mv -f -- "$state_backup" "$STATE_FILE"
  else
    rm -f -- "$STATE_FILE"
  fi
  if [ "$had_config" = 1 ]; then
    systemctl restart "$SERVICE" >/dev/null 2>&1 || true
  else
    systemctl disable "$SERVICE" >/dev/null 2>&1 || true
    if [ -f "$UNIT_FILE" ] && grep -qF '# PNA_MANAGED_COPYPARTY_SYSTEMD_V095' "$UNIT_FILE"; then rm -f -- "$UNIT_FILE"; fi
    rm -rf -- "$PROGRAM_DIR"
    systemctl daemon-reload >/dev/null 2>&1 || true
  fi
}

write_state() {
  local username="$1" quota="$2" minimum_free="$3" status="$4" instance_id="$5" tmp
  install -d -o root -g root -m 0700 "$(dirname "$STATE_FILE")"
  tmp="$(mktemp "$(dirname "$STATE_FILE")/.private-drive.XXXXXX")"
  {
    printf 'PRIVATE_DRIVE_STATE_VERSION=1\n'
    printf 'PRIVATE_DRIVE_MODE=copyparty\n'
    printf 'PRIVATE_DRIVE_STATUS=%s\n' "$status"
    printf 'DRIVE_INSTANCE_ID=%s\n' "$instance_id"
    printf 'DRIVE_ACCOUNT_USERNAME=%s\n' "$username"
    printf 'DRIVE_ACCOUNT_ROLE=admin\n'
    printf 'COPYPARTY_VERSION=%s\n' "$COPYPARTY_VERSION"
    printf 'COPYPARTY_SHA256=%s\n' "$COPYPARTY_SFX_SHA256"
    printf 'COPYPARTY_LISTEN=127.0.0.1:3923\n'
    printf 'PRIVATE_DRIVE_ORIGIN_PORT=2087\n'
    printf 'PRIVATE_DRIVE_QUOTA_GIB=%s\n' "$quota"
    printf 'PRIVATE_DRIVE_MIN_FREE_BYTES=%s\n' "$minimum_free"
    printf 'PRIVATE_DRIVE_UPDATED_AT=%s\n' "$(date -Is)"
  } > "$tmp"
  chmod 0600 "$tmp"
  mv -f -- "$tmp" "$STATE_FILE"
}

wait_ready() {
  local attempt
  for attempt in $(seq 1 80); do
    systemctl is-active --quiet "$SERVICE" && ss -H -lntp 2>/dev/null | awk '$4 == "127.0.0.1:3923" {found=1} END{exit found ? 0 : 1}' && return 0
    sleep 0.25
  done
  echo 'PNA_DRIVE_ERROR=SERVICE_NOT_READY' >&2
  journalctl -u "$SERVICE" -n 20 --no-pager 2>/dev/null | sed -E 's/(PW:|cppwd=|cppws=)[^ ]+/\1<redacted>/g' >&2 || true
  return 147
}

verify_credential_crud() {
  local username="$1" password="$2"
  printf '%s\0%s\0' "$username" "$password" | python3 -c '
import http.client, os, secrets, sys
raw = sys.stdin.buffer.read().split(b"\0")
if len(raw) < 3:
    raise SystemExit(2)
user = raw[0].decode("utf-8", "strict")
password = raw[1].decode("utf-8", "strict")
auth = {"PW": user + ":" + password}

def req(method, path, body=None, headers=None):
    conn = http.client.HTTPConnection("127.0.0.1", 3923, timeout=10)
    h = dict(headers or {})
    conn.request(method, path, body=body, headers=h)
    response = conn.getresponse()
    data = response.read()
    status = response.status
    conn.close()
    return status, data

status, _ = req("GET", "/?ls", headers=auth)
if status != 200:
    raise SystemExit(4)
name = "/.pna-crud-" + secrets.token_hex(8) + ".txt"
payload = b"PNA_COPYPARTY_CRUD_PROBE\n"
status, _ = req("PUT", name, body=payload, headers=auth)
if status not in (200, 201, 204):
    raise SystemExit(5)
anonymous, _ = req("GET", name)
if anonymous not in (401, 403, 404):
    raise SystemExit(3)
status, downloaded = req("GET", name, headers=auth)
if status != 200 or downloaded != payload:
    raise SystemExit(6)
status, _ = req("DELETE", name, headers=auth)
if status not in (200, 202, 204):
    raise SystemExit(7)
status, _ = req("GET", name, headers=auth)
if status not in (403, 404):
    raise SystemExit(8)
' || { echo 'PNA_DRIVE_ERROR=CREDENTIAL_CRUD_VERIFICATION_FAILED' >&2; return 148; }
  echo 'PNA_DRIVE_CREDENTIAL_CRUD_OK'
}

install_or_rotate() {
  local username="${1:-}" quota="${2:-2}" minimum_free salt hash instance_id action="${3:-install}"
  local had_config=0 state_backup=''
  valid_username "$username" || { echo 'PNA_DRIVE_ERROR=USERNAME_INVALID' >&2; return 149; }
  valid_quota "$quota" || { echo 'PNA_DRIVE_ERROR=QUOTA_INVALID' >&2; return 149; }
  read_password
  if ! id copyparty >/dev/null 2>&1; then
    useradd --system --home-dir /var/lib/proxy-node-assistant/copyparty --no-create-home --shell /usr/sbin/nologin copyparty
  fi
  install -d -o root -g root -m 0755 "$PROGRAM_DIR" "$CONFIG_DIR"
  install -d -o copyparty -g copyparty -m 0700 "$DATA_DIR" "$RUNTIME_DIR" "$RUNTIME_DIR/volume" "$LOG_DIR"
  minimum_free="$(disk_budget)"
  pna_load_third_party_lock "$ROOT"
  if [ "$action" = install ] || [ ! -s "$PROGRAM_FILE" ] || ! pna_sha256_check "$COPYPARTY_SFX_SHA256" "$PROGRAM_FILE"; then
    pna_download_copyparty_pinned "$ROOT" "$PROGRAM_FILE"
  fi
  salt="$(openssl rand -hex 24)"
  hash="$(password_hash "$username" "$PNA_DRIVE_PASSWORD" "$salt")"
  [ -f "$CONFIG_FILE" ] && had_config=1
  if [ -f "$STATE_FILE" ]; then
    state_backup="$(mktemp "$(dirname "$STATE_FILE")/.private-drive.rollback.XXXXXX")"
    cp -a -- "$STATE_FILE" "$state_backup"
  fi
  if ! render_config "$username" "$hash" "$salt" "$quota" "$minimum_free"; then
    rollback_config_and_state "$had_config" "$state_backup"
    unset PNA_DRIVE_PASSWORD
    return 146
  fi
  if [ -e "$UNIT_FILE" ] && ! grep -qF '# PNA_MANAGED_COPYPARTY_SYSTEMD_V095' "$UNIT_FILE"; then
    rollback_config_and_state "$had_config" "$state_backup"
    unset PNA_DRIVE_PASSWORD
    echo 'PNA_DRIVE_ERROR=UNMANAGED_UNIT_EXISTS' >&2
    return 146
  fi
  if ! install -o root -g root -m 0644 "$ROOT/templates/systemd/proxy-node-assistant-copyparty.service" "$UNIT_FILE"; then
    rollback_config_and_state "$had_config" "$state_backup"
    unset PNA_DRIVE_PASSWORD
    return 146
  fi
  instance_id="$(state_value DRIVE_INSTANCE_ID || true)"
  [ -n "$instance_id" ] || instance_id="$(openssl rand -hex 16)"
  if ! write_state "$username" "$quota" "$minimum_free" LOCAL_ONLY_READY_WAITING_FOR_CLOUDFLARE "$instance_id"; then
    rollback_config_and_state "$had_config" "$state_backup"
    unset PNA_DRIVE_PASSWORD
    return 146
  fi
  if ! systemctl daemon-reload || ! systemctl enable --now "$SERVICE" >/dev/null || \
     ! systemctl restart "$SERVICE" || ! wait_ready || \
     ! verify_credential_crud "$username" "$PNA_DRIVE_PASSWORD"; then
    rollback_config_and_state "$had_config" "$state_backup"
    unset PNA_DRIVE_PASSWORD
    echo 'PNA_DRIVE_ERROR=TRANSACTION_ROLLED_BACK' >&2
    return 148
  fi
  rm -f -- "$PNA_DRIVE_CONFIG_BACKUP" "$state_backup"
  PNA_DRIVE_CONFIG_BACKUP=''
  unset PNA_DRIVE_PASSWORD
  printf '__PNA_DRIVE_RESULT_BEGIN__\n'
  printf 'PRIVATE_DRIVE_STATUS=LOCAL_ONLY_READY_WAITING_FOR_CLOUDFLARE\n'
  printf 'PRIVATE_DRIVE_MODE=copyparty\n'
  printf 'COPYPARTY_VERSION=%s\n' "$COPYPARTY_VERSION"
  printf 'COPYPARTY_LISTEN=127.0.0.1:3923\n'
  printf 'DRIVE_ACCOUNT_USERNAME=%s\n' "$username"
  printf 'PRIVATE_DRIVE_QUOTA_GIB=%s\n' "$quota"
  printf 'PRIVATE_DRIVE_MIN_FREE_BYTES=%s\n' "$minimum_free"
  printf 'PRIVATE_DRIVE_ORIGIN_RULE=DEFERRED\n'
  printf 'PRIVATE_DRIVE_PUBLIC_ACCESS=BLOCKED\n'
  printf '__PNA_DRIVE_RESULT_END__\n'
}

show_status() {
  local service=inactive listener=0 state=disabled mode=disabled version=unknown quota=unknown account=unknown bytes_used=0
  systemctl is-active --quiet "$SERVICE" && service=active
  ss -H -lntp 2>/dev/null | awk '$4 == "127.0.0.1:3923" {found=1} END{exit found ? 0 : 1}' && listener=1 || true
  state="$(state_value PRIVATE_DRIVE_STATUS || printf disabled)"
  mode="$(state_value PRIVATE_DRIVE_MODE || printf disabled)"
  version="$(state_value COPYPARTY_VERSION || printf unknown)"
  quota="$(state_value PRIVATE_DRIVE_QUOTA_GIB || printf unknown)"
  account="$(state_value DRIVE_ACCOUNT_USERNAME || printf unknown)"
  [ -d "$DATA_DIR" ] && bytes_used="$(du -sb "$DATA_DIR" 2>/dev/null | awk '{print $1}' || printf 0)"
  printf '__PNA_DRIVE_STATUS_BEGIN__\n'
  printf 'PRIVATE_DRIVE_MODE=%s\nPRIVATE_DRIVE_STATUS=%s\nCOPYPARTY_SERVICE=%s\nCOPYPARTY_LOOPBACK_LISTENER=%s\n' "$mode" "$state" "$service" "$listener"
  printf 'COPYPARTY_VERSION=%s\nDRIVE_ACCOUNT_USERNAME=%s\nPRIVATE_DRIVE_QUOTA_GIB=%s\nPRIVATE_DRIVE_USED_BYTES=%s\n' "$version" "$account" "$quota" "$bytes_used"
  printf 'PRIVATE_DRIVE_ORIGIN_RULE=DEFERRED\nPRIVATE_DRIVE_PUBLIC_ACCESS=BLOCKED\n'
  printf '__PNA_DRIVE_STATUS_END__\n'
}

uninstall_preserve() {
  systemctl disable --now "$SERVICE" >/dev/null 2>&1 || true
  rm -f -- "$UNIT_FILE"
  systemctl daemon-reload
  if [ -f "$CONFIG_FILE" ] && grep -qF '# PNA_MANAGED_COPYPARTY_V095' "$CONFIG_FILE"; then rm -f -- "$CONFIG_FILE"; fi
  local candidate
  for candidate in "$CONFIG_DIR"/.copyparty.rollback.* "$CONFIG_FILE".before-*; do
    [ -f "$candidate" ] || continue
    grep -qF '# PNA_MANAGED_COPYPARTY_V095' "$candidate" && rm -f -- "$candidate"
  done
  rm -rf -- "$PROGRAM_DIR"
  local instance_id username quota minimum_free
  instance_id="$(state_value DRIVE_INSTANCE_ID || openssl rand -hex 16)"
  username="$(state_value DRIVE_ACCOUNT_USERNAME || printf unknown)"
  quota="$(state_value PRIVATE_DRIVE_QUOTA_GIB || printf 2)"
  minimum_free="$(state_value PRIVATE_DRIVE_MIN_FREE_BYTES || printf 6442450944)"
  write_state "$username" "$quota" "$minimum_free" DISABLED_DATA_PRESERVED "$instance_id"
  echo 'PNA_DRIVE_UNINSTALLED_DATA_PRESERVED'
}

purge_data() {
  [ "${1:-}" = PURGE-DATA ] || { echo 'PNA_DRIVE_ERROR=PURGE_CONFIRMATION_REQUIRED' >&2; return 150; }
  uninstall_preserve
  rm -rf -- "$DATA_DIR" "$RUNTIME_DIR" "$LOG_DIR"
  rm -f -- "$STATE_FILE"
  echo 'PNA_DRIVE_PURGED'
}

case "${1:-}" in
  install) [ "$#" -eq 3 ] || exit 2; install_or_rotate "$2" "$3" install ;;
  rotate) [ "$#" -eq 3 ] || exit 2; install_or_rotate "$2" "$3" rotate ;;
  verify) [ "$#" -eq 2 ] || exit 2; read_password; wait_ready; verify_credential_crud "$2" "$PNA_DRIVE_PASSWORD"; unset PNA_DRIVE_PASSWORD ;;
  status) [ "$#" -eq 1 ] || exit 2; show_status ;;
  uninstall-preserve) [ "$#" -eq 1 ] || exit 2; uninstall_preserve ;;
  purge) [ "$#" -eq 2 ] || exit 2; purge_data "$2" ;;
  *) echo 'usage: 29-copyparty-drive.sh install USERNAME 2|3 | rotate USERNAME 2|3 | verify USERNAME | status | uninstall-preserve | purge PURGE-DATA' >&2; exit 2 ;;
esac
