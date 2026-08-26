#!/usr/bin/env bash
# Shared TextNodeAssistant private-drive primitives. Source this file; do not execute it.

TNA_DRIVE_CONFIG_DIR=/etc/text-node-assistant
TNA_DRIVE_CONFIG_FILE="$TNA_DRIVE_CONFIG_DIR/copyparty.conf"
TNA_DRIVE_STATE_FILE="$TNA_DRIVE_CONFIG_DIR/private-drive.env"
TNA_DRIVE_REGISTRY_FILE="$TNA_DRIVE_CONFIG_DIR/drive-accounts.tsv"
TNA_DRIVE_ESCROW_DIR="$TNA_DRIVE_CONFIG_DIR/drive-credential-escrow"
TNA_DRIVE_PROGRAM_DIR=/opt/text-node-assistant/copyparty
TNA_DRIVE_PROGRAM_FILE="$TNA_DRIVE_PROGRAM_DIR/copyparty-sfx.py"
TNA_DRIVE_NEW_DATA_ROOT=/srv/text-node-assistant/drive-data
TNA_DRIVE_LEGACY_DATA_ROOT=/srv/proxy-node-assistant/drive-data
TNA_DRIVE_RUNTIME_DIR=/var/lib/text-node-assistant/copyparty
TNA_DRIVE_LOG_DIR=/var/log/text-node-assistant/copyparty
TNA_DRIVE_UNIT_FILE=/etc/systemd/system/text-node-assistant-copyparty.service
TNA_DRIVE_SERVICE=text-node-assistant-copyparty.service
TNA_DRIVE_LOCK_FILE=/var/lib/text-node-assistant/drive-transaction.lock
TNA_DRIVE_SCHEMA_VERSION=2
TNA_DRIVE_ACCOUNT_LIMIT=2
TNA_DRIVE_TXN_DIR=''

tna_drive_prepare_state_root() {
  local state_root
  state_root="$(dirname "$TNA_DRIVE_LOCK_FILE")"
  [ ! -L "$state_root" ] || { echo 'TNA_DRIVE_ERROR=STATE_ROOT_SYMLINK_REFUSED' >&2; return 146; }
  # copyparty must traverse this root to reach its private 0700 runtime dir.
  # 0711 permits traversal only; it does not permit directory listing, while
  # sensitive migration/transaction children and files remain 0700/0600.
  install -d -o root -g root -m 0711 "$state_root"
  [ "$(stat -c '%U:%G:%a' "$state_root")" = 'root:root:711' ] || {
    echo 'TNA_DRIVE_ERROR=STATE_ROOT_PERMISSION_INVALID' >&2; return 146;
  }
}

tna_drive_require_root() {
  [ "$(id -u)" -eq 0 ] || { echo 'TNA_DRIVE_ERROR=ROOT_REQUIRED' >&2; return 141; }
}

tna_drive_state_value() {
  local key="${1:?key required}" line
  [ -r "$TNA_DRIVE_STATE_FILE" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in "${key}="*) printf '%s\n' "${line#*=}"; return 0;; esac
  done < "$TNA_DRIVE_STATE_FILE"
  return 1
}

tna_drive_valid_username() {
  [[ "${1:-}" =~ ^[A-Za-z][A-Za-z0-9._-]{2,31}$ ]]
}

tna_drive_valid_ordinary_username() {
  local lowered
  tna_drive_valid_username "${1:-}" || return 1
  lowered="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
  case "$lowered" in admin|root|administrator|system|copyparty|tnaadmin|tna-admin-*) return 1;; esac
}

tna_drive_valid_admin_username() {
  [[ "${1:-}" =~ ^tna-admin-[a-f0-9]{12}$ ]]
}

tna_drive_read_password() {
  local value=''
  IFS= read -r value || [ -n "$value" ] || { echo 'TNA_DRIVE_ERROR=PASSWORD_STDIN_MISSING' >&2; return 144; }
  [ -n "$value" ] || { echo 'TNA_DRIVE_ERROR=PASSWORD_EMPTY' >&2; return 144; }
  [[ "$value" != *$'\r'* && "$value" != *$'\n'* ]] || {
    echo 'TNA_DRIVE_ERROR=PASSWORD_CONTROL_CHARACTER' >&2; return 144;
  }
  LC_ALL=C grep -qE '^[ -~]{14,128}$' <<<"$value" || {
    echo 'TNA_DRIVE_ERROR=PASSWORD_NOT_PRINTABLE_ASCII_OR_LENGTH_INVALID' >&2; return 144;
  }
  TNA_DRIVE_PASSWORD="$value"
}

tna_drive_random_hex() {
  local bytes="${1:-16}"
  openssl rand -hex "$bytes"
}

tna_drive_data_root() {
  local configured
  configured="$(tna_drive_state_value DRIVE_DATA_ROOT || true)"
  case "$configured" in
    "$TNA_DRIVE_NEW_DATA_ROOT"|"$TNA_DRIVE_LEGACY_DATA_ROOT") printf '%s\n' "$configured"; return 0;;
  esac
  if [ -d "$TNA_DRIVE_LEGACY_DATA_ROOT" ] && [ ! -e "$TNA_DRIVE_NEW_DATA_ROOT" ]; then
    printf '%s\n' "$TNA_DRIVE_LEGACY_DATA_ROOT"
  else
    printf '%s\n' "$TNA_DRIVE_NEW_DATA_ROOT"
  fi
}

tna_drive_choose_port() {
  local saved candidate main_pid
  saved="$(tna_drive_state_value COPYPARTY_LOOPBACK_PORT || true)"
  if [[ "$saved" =~ ^39[0-9]{3}$ ]]; then
    if ! ss -H -lnt 2>/dev/null | awk -v p=":$saved" '$4 ~ p"$" {found=1} END{exit found ? 0 : 1}'; then
      printf '%s\n' "$saved"
      return 0
    fi
    main_pid="$(systemctl show -p MainPID --value "$TNA_DRIVE_SERVICE" 2>/dev/null || true)"
    if [[ "$main_pid" =~ ^[1-9][0-9]*$ ]] && ss -H -lntp 2>/dev/null | awk -v p=":$saved" -v pid="pid=$main_pid," '$4 ~ p"$" && index($0,pid)>0 {found=1} END{exit found ? 0 : 1}'; then
      printf '%s\n' "$saved"
      return 0
    fi
    echo 'TNA_DRIVE_ERROR=SAVED_LOOPBACK_PORT_OCCUPIED_BY_UNKNOWN_PROCESS' >&2
    return 142
  fi
  for candidate in $(seq 39000 39999); do
    if ! ss -H -lnt 2>/dev/null | awk -v p=":$candidate" '$4 ~ p"$" {found=1} END{exit found ? 0 : 1}'; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  echo 'TNA_DRIVE_ERROR=NO_LOOPBACK_PORT_AVAILABLE' >&2
  return 142
}

tna_drive_disk_budget() {
  local root="$1" total available reserve30 reserve6 reserve usable quota
  read -r total available < <(df -B1 --output=size,avail "$root" 2>/dev/null | awk 'NR==2 {print $1, $2}')
  case "$total:$available" in *[!0-9:]*|:*) echo 'TNA_DRIVE_ERROR=DISK_PROBE_FAILED' >&2; return 142;; esac
  reserve6=$((6 * 1024 * 1024 * 1024))
  reserve30=$(((total * 30 + 99) / 100))
  if [ "$reserve30" -gt "$reserve6" ]; then reserve="$reserve30"; else reserve="$reserve6"; fi
  [ "$available" -gt "$reserve" ] || { echo 'TNA_DRIVE_ERROR=MIN_FREE_BUDGET_NOT_MET' >&2; return 143; }
  usable=$((available - reserve))
  quota=$((usable / 3 / 1024 / 1024 / 1024))
  [ "$quota" -ge 1 ] || quota=1
  [ "$quota" -le 50 ] || quota=50
  printf '%s %s\n' "$reserve" "$quota"
}

tna_drive_resolve_quota() {
  local requested="${1:-auto}" adaptive="$2"
  if [ "$requested" = auto ]; then printf '%s\n' "$adaptive"; return 0; fi
  [[ "$requested" =~ ^[0-9]+$ ]] && [ "$requested" -ge 1 ] && [ "$requested" -le 50 ] || {
    echo 'TNA_DRIVE_ERROR=QUOTA_INVALID' >&2; return 149;
  }
  [ "$requested" -le "$adaptive" ] || { echo 'TNA_DRIVE_ERROR=QUOTA_EXCEEDS_ADAPTIVE_LIMIT' >&2; return 149; }
  printf '%s\n' "$requested"
}

tna_drive_password_hash() {
  local username="$1" password="$2" salt="$3" output clean hash
  output="$(printf '%s\n' "${username}:${password}" | NO_COLOR=1 python3 "$TNA_DRIVE_PROGRAM_FILE" \
    --usernames --ah-alg scrypt --ah-salt "$salt" --ah-gen - 2>&1 || true)"
  clean="$(printf '%s\n' "$output" | sed -r 's/\x1B\[[0-9;]*[mK]//g')"
  hash="$(printf '%s\n' "$clean" | grep -E '^\+[A-Za-z0-9+/=_-]+$' | tail -1 || true)"
  [[ "$hash" =~ ^\+[A-Za-z0-9+/=_-]{20,200}$ ]] || { echo 'TNA_DRIVE_ERROR=PASSWORD_HASH_FAILED' >&2; return 145; }
  printf '%s\n' "$hash"
}

tna_drive_prepare_base() {
  local root="$1" data_root
  tna_drive_require_root
  tna_load_third_party_lock "$root" || { echo 'TNA_DRIVE_ERROR=THIRD_PARTY_LOCK_INVALID' >&2; return 141; }
  if ! id copyparty >/dev/null 2>&1; then
    useradd --system --home-dir "$TNA_DRIVE_RUNTIME_DIR" --no-create-home --shell /usr/sbin/nologin copyparty
  fi
  tna_drive_prepare_state_root
  data_root="$(tna_drive_data_root)"
  install -d -o root -g root -m 0755 "$TNA_DRIVE_PROGRAM_DIR" "$TNA_DRIVE_CONFIG_DIR"
  install -d -o root -g root -m 0700 "$TNA_DRIVE_ESCROW_DIR"
  install -d -o copyparty -g copyparty -m 0700 "$data_root" "$data_root/spaces" "$TNA_DRIVE_RUNTIME_DIR" "$TNA_DRIVE_RUNTIME_DIR/volume" "$TNA_DRIVE_LOG_DIR"
  if [ ! -s "$TNA_DRIVE_PROGRAM_FILE" ] || ! tna_sha256_check "$COPYPARTY_SFX_SHA256" "$TNA_DRIVE_PROGRAM_FILE"; then
    tna_download_copyparty_pinned "$root" "$TNA_DRIVE_PROGRAM_FILE"
  fi
  chown root:root "$TNA_DRIVE_PROGRAM_FILE"
  chmod 0755 "$TNA_DRIVE_PROGRAM_FILE"
}

tna_drive_lock() {
  tna_drive_prepare_state_root
  exec 8>"$TNA_DRIVE_LOCK_FILE"
  flock -x 8
}

tna_drive_txn_begin() {
  TNA_DRIVE_TXN_DIR="$(mktemp -d /var/lib/text-node-assistant/.drive-txn.XXXXXX)"
  chmod 0700 "$TNA_DRIVE_TXN_DIR"
  trap 'tna_drive_txn_exit "$?"' EXIT
  local item label
  for item in "$TNA_DRIVE_CONFIG_FILE" "$TNA_DRIVE_STATE_FILE" "$TNA_DRIVE_REGISTRY_FILE" "$TNA_DRIVE_UNIT_FILE"; do
    label="$(printf '%s' "$item" | sed 's|/|_|g')"
    if [ -e "$item" ]; then
      [ ! -L "$item" ] || { echo 'TNA_DRIVE_ERROR=SYMLINK_REFUSED' >&2; return 146; }
      printf '1\n' > "$TNA_DRIVE_TXN_DIR/$label.exists"
      cp -a -- "$item" "$TNA_DRIVE_TXN_DIR/$label"
    else
      printf '0\n' > "$TNA_DRIVE_TXN_DIR/$label.exists"
    fi
  done
}

tna_drive_txn_restore_one() {
  local item="$1" label exists
  label="$(printf '%s' "$item" | sed 's|/|_|g')"
  exists="$(cat "$TNA_DRIVE_TXN_DIR/$label.exists" 2>/dev/null || printf 0)"
  if [ "$exists" = 1 ]; then
    cp -a -- "$TNA_DRIVE_TXN_DIR/$label" "$item"
  else
    rm -f -- "$item"
  fi
}

tna_drive_txn_mark_created_dir() {
  local path="$1" data_root
  data_root="$(tna_drive_data_root)"
  case "$path" in "$data_root"/spaces/tna-space-[a-f0-9]*) ;; *) echo 'TNA_DRIVE_ERROR=CREATED_DIR_SCOPE_INVALID' >&2; return 146;; esac
  printf '%s\n' "$path" >> "$TNA_DRIVE_TXN_DIR/created-dirs"
}

tna_drive_txn_track_escrow() {
  local account_id="$1" path exists
  [[ "$account_id" =~ ^tna-account-[a-f0-9]{32}$ ]] || return 146
  path="$TNA_DRIVE_ESCROW_DIR/$account_id.json"
  printf '%s\n' "$path" > "$TNA_DRIVE_TXN_DIR/escrow.path"
  if [ -f "$path" ]; then
    cp -a -- "$path" "$TNA_DRIVE_TXN_DIR/escrow.json"
    printf '1\n' > "$TNA_DRIVE_TXN_DIR/escrow.exists"
  else
    printf '0\n' > "$TNA_DRIVE_TXN_DIR/escrow.exists"
  fi
}

tna_drive_txn_rollback() {
  local escrow_path created_dir
  [ -n "$TNA_DRIVE_TXN_DIR" ] && [ -d "$TNA_DRIVE_TXN_DIR" ] || return 0
  trap - EXIT
  # Stop and clear any queued Restart=on-failure job before restoring files.
  # A plain restart can otherwise leave an old process listening on the saved
  # loopback port while the new transaction validates against stale accounts.
  systemctl disable --now "$TNA_DRIVE_SERVICE" >/dev/null 2>&1 || true
  systemctl reset-failed "$TNA_DRIVE_SERVICE" >/dev/null 2>&1 || true
  tna_drive_txn_restore_one "$TNA_DRIVE_CONFIG_FILE"
  tna_drive_txn_restore_one "$TNA_DRIVE_STATE_FILE"
  tna_drive_txn_restore_one "$TNA_DRIVE_REGISTRY_FILE"
  tna_drive_txn_restore_one "$TNA_DRIVE_UNIT_FILE"
  if [ -f "$TNA_DRIVE_TXN_DIR/escrow.path" ]; then
    escrow_path="$(cat "$TNA_DRIVE_TXN_DIR/escrow.path")"
    case "$escrow_path" in "$TNA_DRIVE_ESCROW_DIR"/tna-account-[a-f0-9]*.json) ;; *) escrow_path='';; esac
    if [ -n "$escrow_path" ]; then
      if [ "$(cat "$TNA_DRIVE_TXN_DIR/escrow.exists" 2>/dev/null || printf 0)" = 1 ]; then
        cp -a -- "$TNA_DRIVE_TXN_DIR/escrow.json" "$escrow_path"
      else
        rm -f -- "$escrow_path"
      fi
    fi
  fi
  if [ -f "$TNA_DRIVE_TXN_DIR/created-dirs" ]; then
    while IFS= read -r created_dir; do
      rmdir -- "$created_dir" >/dev/null 2>&1 || true
    done < "$TNA_DRIVE_TXN_DIR/created-dirs"
  fi
  systemctl daemon-reload >/dev/null 2>&1 || true
  if [ -f "$TNA_DRIVE_UNIT_FILE" ] && [ -f "$TNA_DRIVE_CONFIG_FILE" ]; then
    systemctl reset-failed "$TNA_DRIVE_SERVICE" >/dev/null 2>&1 || true
    systemctl start "$TNA_DRIVE_SERVICE" >/dev/null 2>&1 || true
  fi
  rm -rf -- "$TNA_DRIVE_TXN_DIR"
  TNA_DRIVE_TXN_DIR=''
  echo 'TNA_DRIVE_ERROR=TRANSACTION_ROLLED_BACK' >&2
}

tna_drive_txn_commit() {
  trap - EXIT
  [ -n "$TNA_DRIVE_TXN_DIR" ] && rm -rf -- "$TNA_DRIVE_TXN_DIR"
  TNA_DRIVE_TXN_DIR=''
}

tna_drive_txn_exit() {
  local rc="$1"
  trap - EXIT
  if [ -n "$TNA_DRIVE_TXN_DIR" ] && [ -d "$TNA_DRIVE_TXN_DIR" ]; then
    tna_drive_txn_rollback || true
  fi
  exit "$rc"
}

tna_drive_registry_admin_line() {
  awk -F '\t' '$3=="admin" && $4=="active" {print; exit}' "$TNA_DRIVE_REGISTRY_FILE" 2>/dev/null
}

tna_drive_registry_find_user() {
  local username="$1"
  awk -F '\t' -v u="$username" '$5==u {print; exit}' "$TNA_DRIVE_REGISTRY_FILE" 2>/dev/null
}

tna_drive_active_ordinary_count() {
  # A node with the mandatory drive removed has no registry yet.  Status is a
  # read-only probe and must still return a structured DISABLED result instead
  # of aborting under set -e because awk cannot open a missing file.
  awk -F '\t' '$3=="ordinary" && ($4=="active" || $4=="paused") {n++} END{print n+0}' "$TNA_DRIVE_REGISTRY_FILE" 2>/dev/null || printf '0\n'
}

tna_drive_validate_registry() {
  local line account_id space_id role status username hash quota created admins=0 ordinary=0 seen='|'
  [ -s "$TNA_DRIVE_REGISTRY_FILE" ] || { echo 'TNA_DRIVE_ERROR=REGISTRY_EMPTY' >&2; return 146; }
  while IFS=$'\t' read -r account_id space_id role status username hash quota created extra || [ -n "$account_id" ]; do
    [ -z "${extra:-}" ] || return 146
    [[ "$account_id" =~ ^tna-account-[a-f0-9]{32}$ ]] || return 146
    [[ "$space_id" =~ ^tna-space-[a-f0-9]{32}$ ]] || return 146
    tna_drive_valid_username "$username" || return 146
    [[ "$hash" =~ ^\+[A-Za-z0-9+/=_-]{20,200}$ ]] || return 146
    [[ "$quota" =~ ^[0-9]+$ ]] && [ "$quota" -ge 1 ] && [ "$quota" -le 50 ] || return 146
    case "$status" in active|paused|revoked) ;; *) return 146;; esac
    case "$role" in admin) [ "$status" = active ] || return 146; admins=$((admins+1));; ordinary) [ "$status" = revoked ] || ordinary=$((ordinary+1));; *) return 146;; esac
    case "$seen" in *"|$username|"*) return 146;; esac
    seen="${seen}${username}|"
  done < "$TNA_DRIVE_REGISTRY_FILE"
  [ "$admins" -eq 1 ] && [ "$ordinary" -le "$TNA_DRIVE_ACCOUNT_LIMIT" ] || {
    echo 'TNA_DRIVE_ERROR=REGISTRY_INVARIANT_FAILED' >&2; return 146;
  }
}

tna_drive_render_config() {
  local port="$1" salt="$2" data_root="$3" minimum_free="$4" tmp admin_line admin_user admin_quota
  local account_status account_username account_hash account_space_id account_role account_quota
  tna_drive_validate_registry
  admin_line="$(tna_drive_registry_admin_line)"
  IFS=$'\t' read -r _ _ _ _ admin_user _ admin_quota _ <<<"$admin_line"
  tmp="$(mktemp "$TNA_DRIVE_CONFIG_DIR/.copyparty.conf.XXXXXX")"
  {
    printf '# TNA_MANAGED_COPYPARTY_V095\n[global]\n'
    printf '  i: 127.0.0.1\n  p: %s\n  j: 1\n  name: TextNode Drive\n' "$port"
    printf '  http-only\n  no-crt\n  usernames\n  no-robots\n  no-logues\n  no-readme\n  no-thumb\n  no-mtag-ff\n'
    printf '  ah-alg: scrypt\n  ah-salt: %s\n\n[accounts]\n' "$salt"
    while IFS=$'\t' read -r _ _ _ account_status account_username account_hash _ _; do
      [ "$account_status" = active ] || continue
      printf '  %s: %s\n' "$account_username" "$account_hash"
    done < "$TNA_DRIVE_REGISTRY_FILE"
    printf '\n[/files/admin]\n  %s\n  accs:\n    rwdma: %s\n  flags:\n' "$data_root" "$admin_user"
    printf '    e2ds\n    hist: %s/volume/admin\n    u2sz: 1,64,64\n    vmaxb: %sg\n    vmaxn: 100k\n    df: %sb\n    grid\n    xvol\n    xdev\n    nohtml\n    no_logues\n    no_readme\n    dthumb\n    d2t\n' "$TNA_DRIVE_RUNTIME_DIR" "$admin_quota" "$minimum_free"
    while IFS=$'\t' read -r _ account_space_id account_role account_status account_username _ account_quota _; do
      [ "$account_role" = ordinary ] && [ "$account_status" = active ] || continue
      printf '\n[/files/%s]\n  %s/spaces/%s\n  accs:\n    rwdma: %s, %s\n  flags:\n' "$account_username" "$data_root" "$account_space_id" "$account_username" "$admin_user"
      printf '    e2ds\n    hist: %s/volume/%s\n    u2sz: 1,64,64\n    vmaxb: %sg\n    vmaxn: 100k\n    df: %sb\n    grid\n    xvol\n    xdev\n    nohtml\n    no_logues\n    no_readme\n    dthumb\n    d2t\n' "$TNA_DRIVE_RUNTIME_DIR" "$account_space_id" "$account_quota" "$minimum_free"
    done < "$TNA_DRIVE_REGISTRY_FILE"
  } > "$tmp"
  chmod 0640 "$tmp"
  chown root:copyparty "$tmp"
  mv -f -- "$tmp" "$TNA_DRIVE_CONFIG_FILE"
}

tna_drive_render_unit() {
  local root="$1" data_root="$2" port="$3" tmp
  if [ -e "$TNA_DRIVE_UNIT_FILE" ] && ! grep -qF '# TNA_MANAGED_COPYPARTY_SYSTEMD_V095' "$TNA_DRIVE_UNIT_FILE"; then
    echo 'TNA_DRIVE_ERROR=UNMANAGED_UNIT_EXISTS' >&2
    return 146
  fi
  tmp="$(mktemp /etc/systemd/system/.text-node-assistant-copyparty.XXXXXX)"
  sed -e "s|@DATA_ROOT@|$data_root|g" -e "s|@LOOPBACK_PORT@|$port|g" \
    "$root/templates/systemd/text-node-assistant-copyparty.service" > "$tmp"
  grep -qF '# TNA_MANAGED_COPYPARTY_SYSTEMD_V095' "$tmp" || { rm -f -- "$tmp"; return 146; }
  grep -qF ' -i 127.0.0.1 ' "$tmp" || { rm -f -- "$tmp"; return 146; }
  grep -qF " -p $port " "$tmp" || { rm -f -- "$tmp"; return 146; }
  grep -qF 'AF_NETLINK' "$tmp" || { rm -f -- "$tmp"; return 146; }
  chmod 0644 "$tmp"
  chown root:root "$tmp"
  mv -f -- "$tmp" "$TNA_DRIVE_UNIT_FILE"
}

tna_drive_write_state() {
  local data_root="$1" port="$2" salt="$3" minimum_free="$4" lifecycle="$5" ready="$6" admin_line admin_id admin_space tmp
  admin_line="$(tna_drive_registry_admin_line)"
  IFS=$'\t' read -r admin_id admin_space _ _ _ _ _ _ <<<"$admin_line"
  tmp="$(mktemp "$TNA_DRIVE_CONFIG_DIR/.private-drive.XXXXXX")"
  {
    printf 'PRIVATE_DRIVE_STATE_VERSION=%s\n' "$TNA_DRIVE_SCHEMA_VERSION"
    printf 'PRIVATE_DRIVE_MODE=copyparty\nPRIVATE_DRIVE_STATUS=READY\n'
    printf 'DRIVE_DATA_ROOT=%s\nCOPYPARTY_VERSION=%s\nCOPYPARTY_SHA256=%s\n' "$data_root" "$COPYPARTY_VERSION" "$COPYPARTY_SFX_SHA256"
    printf 'COPYPARTY_LOOPBACK_PORT=%s\nCOPYPARTY_LISTEN=127.0.0.1:%s\n' "$port" "$port"
    printf 'DRIVE_PASSWORD_SALT=%s\nPRIVATE_DRIVE_MIN_FREE_BYTES=%s\n' "$salt" "$minimum_free"
    printf 'ADMIN_ACCOUNT_ID=%s\nADMIN_SPACE_ID=%s\nDRIVE_ACCOUNT_LIMIT=%s\n' "$admin_id" "$admin_space" "$TNA_DRIVE_ACCOUNT_LIMIT"
    printf 'NODE_LIFECYCLE_STATE=%s\nDRIVE_REGISTRATION_READY=%s\n' "$lifecycle" "$ready"
    printf 'PRIVATE_DRIVE_PUBLIC_ACCESS=BLOCKED\nPRIVATE_DRIVE_UPDATED_AT=%s\n' "$(date -Is)"
  } > "$tmp"
  chmod 0600 "$tmp"
  chown root:root "$tmp"
  mv -f -- "$tmp" "$TNA_DRIVE_STATE_FILE"
}

tna_drive_wait_ready() {
  local port="$1" attempt
  for attempt in $(seq 1 80); do
    if systemctl is-active --quiet "$TNA_DRIVE_SERVICE" && ss -H -lntp 2>/dev/null | awk -v p="127.0.0.1:$port" '$4==p {found=1} END{exit found ? 0 : 1}'; then
      return 0
    fi
    sleep 0.25
  done
  echo 'TNA_DRIVE_ERROR=SERVICE_NOT_READY' >&2
  journalctl -u "$TNA_DRIVE_SERVICE" -n 20 --no-pager 2>/dev/null |
    sed -E 's/invalid password:.*/invalid password: <redacted>/; s/(PW:|cppwd=|cppws=)[^ ]+/\1<redacted>/g' >&2 || true
  return 147
}

tna_drive_verify_login() {
  local port="$1" username="$2" password="$3" path="$4" expected="${5:-success}"
  TNA_VERIFY_PORT="$port" TNA_VERIFY_USER="$username" TNA_VERIFY_PATH="$path" TNA_VERIFY_EXPECTED="$expected" \
    python3 -c '
import http.client, os, sys
p=int(os.environ["TNA_VERIFY_PORT"]); u=os.environ["TNA_VERIFY_USER"]; path=os.environ["TNA_VERIFY_PATH"]
pw=sys.stdin.buffer.read().decode("utf-8", "strict").rstrip("\n")
c=http.client.HTTPConnection("127.0.0.1", p, timeout=10)
c.request("GET", path+"?ls", headers={"PW":u+":"+pw})
r=c.getresponse(); r.read(); status=r.status; c.close()
ok=status==200
raise SystemExit(0 if (ok == (os.environ["TNA_VERIFY_EXPECTED"]=="success")) else 1)
' <<<"$password"
}

tna_drive_verify_crud() {
  local port="$1" username="$2" password="$3" path="$4"
  TNA_VERIFY_PORT="$port" TNA_VERIFY_USER="$username" TNA_VERIFY_PATH="$path" python3 -c '
import http.client, os, secrets, sys
p=int(os.environ["TNA_VERIFY_PORT"]); u=os.environ["TNA_VERIFY_USER"]; base=os.environ["TNA_VERIFY_PATH"].rstrip("/")
pw=sys.stdin.buffer.read().decode("utf-8", "strict").rstrip("\n"); auth={"PW":u+":"+pw}
def req(method,path,body=None,headers=None):
 c=http.client.HTTPConnection("127.0.0.1",p,timeout=10); c.request(method,path,body=body,headers=dict(headers or {})); r=c.getresponse(); d=r.read(); s=r.status; c.close(); return s,d
def fail(step,status):
 print("TNA_DRIVE_CRUD_STEP_FAILED=%s HTTP_STATUS=%s"%(step,status),file=sys.stderr); raise SystemExit(9)
s,_=req("GET",base+"/?ls",headers=auth)
if s!=200: fail("AUTHENTICATED_LIST",s)
name=base+"/.tna-crud-"+secrets.token_hex(8)+".txt"; payload=b"TNA_COPYPARTY_CRUD_PROBE\n"
s,_=req("PUT",name,body=payload,headers=auth)
if s not in (200,201,204): fail("AUTHENTICATED_PUT",s)
s,_=req("GET",name+"?dl")
if s not in (401,403,404): fail("ANONYMOUS_DOWNLOAD_WAS_NOT_BLOCKED",s)
s,d=req("GET",name+"?dl",headers=auth)
if s!=200: fail("AUTHENTICATED_DOWNLOAD",s)
if d!=payload: fail("AUTHENTICATED_DOWNLOAD_PAYLOAD_MISMATCH",s)
# The documented Copyparty delete API is POST ?delete, not HTTP DELETE.
s,_=req("POST",name+"?delete",body=b"",headers=auth)
if s not in (200,202,204): fail("AUTHENTICATED_DELETE",s)
s,_=req("GET",name+"?dl",headers=auth)
if s not in (403,404): fail("DELETE_READBACK",s)
' <<<"$password" || { echo 'TNA_DRIVE_ERROR=CREDENTIAL_CRUD_VERIFICATION_FAILED' >&2; return 148; }
  echo 'TNA_DRIVE_CREDENTIAL_CRUD_OK'
}

tna_drive_apply() {
  local root="$1" data_root="$2" port="$3" salt="$4" minimum_free="$5" lifecycle="$6" ready="$7"
  tna_drive_validate_registry || return
  tna_drive_render_config "$port" "$salt" "$data_root" "$minimum_free" || return
  tna_drive_render_unit "$root" "$data_root" "$port" || return
  tna_drive_write_state "$data_root" "$port" "$salt" "$minimum_free" "$lifecycle" "$ready" || return
  # Never validate against a stale listener.  Copyparty is configured with
  # Restart=on-failure, so disable/stop/reset before replacing its unit and
  # start it explicitly after daemon-reload.
  systemctl disable --now "$TNA_DRIVE_SERVICE" >/dev/null 2>&1 || true
  systemctl reset-failed "$TNA_DRIVE_SERVICE" >/dev/null 2>&1 || true
  systemctl daemon-reload
  systemctl enable "$TNA_DRIVE_SERVICE" >/dev/null
  systemctl start "$TNA_DRIVE_SERVICE"
  tna_drive_wait_ready "$port"
}

tna_drive_account_path() {
  local role="$1" username="$2"
  if [ "$role" = admin ]; then printf '/files/admin\n'; else printf '/files/%s\n' "$username"; fi
}

tna_drive_lifecycle_allows_registration() {
  case "${1:-}" in
    MANAGED_GRAY_WITH_DRIVE|MANAGED_ORANGE_WITH_DRIVE|MANAGED_DUAL_WITH_DRIVE) return 0;;
    *) return 1;;
  esac
}
