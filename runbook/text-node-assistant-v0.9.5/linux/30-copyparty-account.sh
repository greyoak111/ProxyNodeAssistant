#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/linux/lib-third-party.sh"
. "$ROOT/linux/lib-drive.sh"

tna_account_load_runtime() {
  TNA_ACCOUNT_DATA_ROOT="$(tna_drive_data_root)"
  TNA_ACCOUNT_PORT="$(tna_drive_state_value COPYPARTY_LOOPBACK_PORT)"
  TNA_ACCOUNT_SALT="$(tna_drive_state_value DRIVE_PASSWORD_SALT)"
  TNA_ACCOUNT_MINIMUM_FREE="$(tna_drive_state_value PRIVATE_DRIVE_MIN_FREE_BYTES)"
  TNA_ACCOUNT_LIFECYCLE="$(tna_drive_state_value NODE_LIFECYCLE_STATE)"
  TNA_ACCOUNT_READY="$(tna_drive_state_value DRIVE_REGISTRATION_READY)"
}

tna_account_require_ready() {
  tna_account_load_runtime
  [ "$TNA_ACCOUNT_READY" = 1 ] && tna_drive_lifecycle_allows_registration "$TNA_ACCOUNT_LIFECYCLE" || {
    echo 'TNA_DRIVE_ERROR=REGISTRATION_NOT_READY' >&2; return 151;
  }
  tna_drive_wait_ready "$TNA_ACCOUNT_PORT"
  tna_drive_validate_registry
}

tna_account_apply() {
  tna_drive_apply "$ROOT" "$TNA_ACCOUNT_DATA_ROOT" "$TNA_ACCOUNT_PORT" "$TNA_ACCOUNT_SALT" "$TNA_ACCOUNT_MINIMUM_FREE" "$TNA_ACCOUNT_LIFECYCLE" "$TNA_ACCOUNT_READY"
}

tna_account_read_escrow() {
  local encoded='' account_id="$1" space_id="$2" username="$3" coverage="${4:-active-only}" node_id controller_id controller_public status_filter
  IFS= read -r encoded || [ -n "$encoded" ] || { echo 'TNA_DRIVE_ERROR=ESCROW_STDIN_MISSING' >&2; return 155; }
  [ "${#encoded}" -ge 80 ] && [ "${#encoded}" -le 48000 ] && [[ "$encoded" =~ ^[A-Za-z0-9_-]+$ ]] || { echo 'TNA_DRIVE_ERROR=ESCROW_ENCODING_INVALID' >&2; return 155; }
  TNA_ACCOUNT_ESCROW_JSON="$(printf '%s' "$encoded" | python3 -c 'import base64,sys
s=sys.stdin.buffer.read(); s+=b"="*((4-len(s)%4)%4)
try: d=base64.urlsafe_b64decode(s)
except Exception: raise SystemExit(2)
if len(d)>32768: raise SystemExit(3)
sys.stdout.buffer.write(d)' 2>/dev/null)" || { echo 'TNA_DRIVE_ERROR=ESCROW_ENCODING_INVALID' >&2; return 155; }
  node_id="$(jq -r '.nodeId' /etc/text-node-assistant/device-registry.json 2>/dev/null || true)"
  jq -e --arg node "$node_id" --arg account "$account_id" --arg space "$space_id" --arg user "$username" '
    .version==1 and .nodeId==$node and .accountId==$account and .spaceId==$space and .username==$user and
    (.ciphertext.nonce|test("^[A-Za-z0-9_-]{16,64}$")) and (.ciphertext.data|test("^[A-Za-z0-9_-]{20,512}$")) and
    (.envelopes|type=="array" and length>=1) and
    (([.envelopes[].deviceId]|length) == ([.envelopes[].deviceId]|unique|length)) and
    all(.envelopes[]; (.deviceId|test("^tna-device-[a-z2-7]{26}$")) and
      (.encryptionPublicKey|test("^tna-x25519:[A-Za-z0-9_-]{43}$")) and
      (.ephemeralPublicKey|test("^tna-x25519:[A-Za-z0-9_-]{43}$")) and
      (.nonce|test("^[A-Za-z0-9_-]{16,64}$")) and (.wrappedKey|test("^[A-Za-z0-9_-]{40,256}$")))
  ' <<<"$TNA_ACCOUNT_ESCROW_JSON" >/dev/null || { echo 'TNA_DRIVE_ERROR=ESCROW_SCHEMA_INVALID' >&2; return 155; }
	case "$coverage" in
		active-only) status_filter='select(.role=="controller" and .status=="active")' ;;
		include-pending) status_filter='select(.role=="controller" and (.status=="active" or .status=="pending-verification"))' ;;
		*) echo 'TNA_DRIVE_ERROR=ESCROW_COVERAGE_MODE_INVALID' >&2; return 155 ;;
	esac
  while IFS=$'\t' read -r controller_id controller_public; do
    [ -n "$controller_id" ] || continue
    jq -e --arg id "$controller_id" --arg public "$controller_public" 'any(.envelopes[]; .deviceId==$id and .encryptionPublicKey==$public)' <<<"$TNA_ACCOUNT_ESCROW_JSON" >/dev/null || {
      echo 'TNA_DRIVE_ERROR=ESCROW_CONTROLLER_COVERAGE_INCOMPLETE' >&2; return 155;
    }
  done < <(jq -r ".devices[] | ${status_filter} | [.deviceId,.encryptionPublicKey] | @tsv" /etc/text-node-assistant/device-registry.json)
}

tna_account_write_escrow() {
  local account_id="$1" tmp
  tna_drive_txn_track_escrow "$account_id"
  tmp="$(mktemp "$TNA_DRIVE_ESCROW_DIR/.escrow.XXXXXX")"
  printf '%s\n' "$TNA_ACCOUNT_ESCROW_JSON" > "$tmp"
  jq -e . "$tmp" >/dev/null || { rm -f -- "$tmp"; return 155; }
  chmod 0600 "$tmp"; chown root:root "$tmp"
  mv -f -- "$tmp" "$TNA_DRIVE_ESCROW_DIR/$account_id.json"
}

tna_account_register() {
  local username="${1:-}" requested="${2:-auto}" account_id="${3:-}" space_id="${4:-}" minimum_free adaptive quota hash created new_dir current_count
  tna_drive_valid_ordinary_username "$username" || { echo 'TNA_DRIVE_ERROR=ORDINARY_USERNAME_INVALID' >&2; return 149; }
  tna_drive_read_password
  [[ "$account_id" =~ ^tna-account-[a-f0-9]{32}$ ]] || { echo 'TNA_DRIVE_ERROR=ACCOUNT_ID_INVALID' >&2; return 149; }
  [[ "$space_id" =~ ^tna-space-[a-f0-9]{32}$ ]] || { echo 'TNA_DRIVE_ERROR=SPACE_ID_INVALID' >&2; return 149; }
  tna_account_read_escrow "$account_id" "$space_id" "$username"
  tna_drive_prepare_base "$ROOT"
  tna_drive_lock
  tna_account_require_ready
  [ -z "$(tna_drive_registry_find_user "$username" || true)" ] || { echo 'TNA_DRIVE_ERROR=USERNAME_ALREADY_EXISTS' >&2; return 152; }
  ! awk -F '\t' -v account="$account_id" -v space="$space_id" '$1==account || $2==space {found=1} END{exit found ? 0 : 1}' "$TNA_DRIVE_REGISTRY_FILE" || { echo 'TNA_DRIVE_ERROR=ACCOUNT_OR_SPACE_ID_ALREADY_EXISTS' >&2; return 152; }
  current_count="$(tna_drive_active_ordinary_count)"
  [ "$current_count" -lt "$TNA_DRIVE_ACCOUNT_LIMIT" ] || { printf 'TNA_DRIVE_ERROR=DRIVE_ACCOUNT_LIMIT_REACHED current=%s limit=%s\n' "$current_count" "$TNA_DRIVE_ACCOUNT_LIMIT" >&2; return 152; }
  read -r minimum_free adaptive < <(tna_drive_disk_budget "$TNA_ACCOUNT_DATA_ROOT")
  quota="$(tna_drive_resolve_quota "$requested" "$adaptive")"
  hash="$(tna_drive_password_hash "$username" "$TNA_DRIVE_PASSWORD" "$TNA_ACCOUNT_SALT")"
  created="$(date -Is)"
  new_dir="$TNA_ACCOUNT_DATA_ROOT/spaces/$space_id"
  tna_drive_txn_begin
  install -d -o copyparty -g copyparty -m 0700 "$new_dir"
  tna_drive_txn_mark_created_dir "$new_dir"
  tna_account_write_escrow "$account_id"
  printf '%s\t%s\tordinary\tactive\t%s\t%s\t%s\t%s\n' "$account_id" "$space_id" "$username" "$hash" "$quota" "$created" >> "$TNA_DRIVE_REGISTRY_FILE"
  if ! tna_account_apply || ! tna_drive_verify_crud "$TNA_ACCOUNT_PORT" "$username" "$TNA_DRIVE_PASSWORD" "/files/$username"; then
    tna_drive_txn_rollback
    unset TNA_DRIVE_PASSWORD
    return 148
  fi
  tna_drive_txn_commit
  unset TNA_ACCOUNT_ESCROW_JSON
  unset TNA_DRIVE_PASSWORD
  printf '__TNA_DRIVE_ACCOUNT_RESULT_BEGIN__\nDRIVE_ACCOUNT_CREATED=1\nDRIVE_ACCOUNT_ID=%s\nDRIVE_SPACE_ID=%s\n' "$account_id" "$space_id"
  printf 'DRIVE_ACCOUNT_USERNAME=%s\nDRIVE_ACCOUNT_PATH=/files/%s/\nDRIVE_ACCOUNT_QUOTA_GIB=%s\n' "$username" "$username" "$quota"
  printf '__TNA_DRIVE_ACCOUNT_RESULT_END__\n'
}

tna_account_change_password() {
  local username="${1:-}" line account_id space_id role status old_hash quota created old_password new_password confirm new_hash
  tna_drive_valid_ordinary_username "$username" || { echo 'TNA_DRIVE_ERROR=ORDINARY_USERNAME_INVALID' >&2; return 149; }
  tna_drive_read_password; old_password="$TNA_DRIVE_PASSWORD"; unset TNA_DRIVE_PASSWORD
  tna_drive_read_password; new_password="$TNA_DRIVE_PASSWORD"; unset TNA_DRIVE_PASSWORD
  tna_drive_read_password; confirm="$TNA_DRIVE_PASSWORD"; unset TNA_DRIVE_PASSWORD
  [ "$new_password" = "$confirm" ] || { echo 'TNA_DRIVE_ERROR=PASSWORD_CONFIRMATION_MISMATCH' >&2; return 144; }
  tna_drive_prepare_base "$ROOT"
  tna_drive_lock
  tna_account_require_ready
  line="$(tna_drive_registry_find_user "$username" || true)"
  [ -n "$line" ] || { echo 'TNA_DRIVE_ERROR=ACCOUNT_NOT_FOUND' >&2; return 152; }
  IFS=$'\t' read -r account_id space_id role status _ old_hash quota created <<<"$line"
  [ "$role" = ordinary ] && [ "$status" = active ] || { echo 'TNA_DRIVE_ERROR=ACCOUNT_NOT_ACTIVE' >&2; return 152; }
  tna_drive_verify_login "$TNA_ACCOUNT_PORT" "$username" "$old_password" "/files/$username" success || { echo 'TNA_DRIVE_ERROR=OLD_PASSWORD_REJECTED' >&2; return 153; }
  tna_account_read_escrow "$account_id" "$space_id" "$username"
  new_hash="$(tna_drive_password_hash "$username" "$new_password" "$TNA_ACCOUNT_SALT")"
  tna_drive_txn_begin
  tna_account_write_escrow "$account_id"
  awk -F '\t' -v OFS='\t' -v u="$username" -v h="$new_hash" '$5==u {$6=h} {print}' "$TNA_DRIVE_REGISTRY_FILE" > "$TNA_DRIVE_REGISTRY_FILE.next"
  chmod 0600 "$TNA_DRIVE_REGISTRY_FILE.next" && mv -f -- "$TNA_DRIVE_REGISTRY_FILE.next" "$TNA_DRIVE_REGISTRY_FILE"
  if ! tna_account_apply || ! tna_drive_verify_crud "$TNA_ACCOUNT_PORT" "$username" "$new_password" "/files/$username" || \
     ! tna_drive_verify_login "$TNA_ACCOUNT_PORT" "$username" "$old_password" "/files/$username" failure; then
    tna_drive_txn_rollback
    return 148
  fi
  tna_drive_txn_commit
  unset TNA_ACCOUNT_ESCROW_JSON
  printf 'TNA_DRIVE_ACCOUNT_PASSWORD_CHANGED=1\nDRIVE_ACCOUNT_ID=%s\nDRIVE_ACCOUNT_USERNAME=%s\n' "$account_id" "$username"
}

tna_account_replace_escrow() {
	local requester="${1:-}" account_id="${2:-}" line space_id role status username
	[[ "$requester" =~ ^tna-device-[a-z2-7]{26}$ ]] || { echo 'TNA_DRIVE_ERROR=REQUESTER_DEVICE_INVALID' >&2; return 155; }
	[[ "$account_id" =~ ^tna-account-[a-f0-9]{32}$ ]] || { echo 'TNA_DRIVE_ERROR=ACCOUNT_ID_INVALID' >&2; return 155; }
	tna_drive_prepare_base "$ROOT"
	tna_drive_lock
	jq -e --arg id "$requester" 'any(.devices[]?; .deviceId==$id and .role=="controller" and .status=="active")' /etc/text-node-assistant/device-registry.json >/dev/null || {
		echo 'TNA_DRIVE_ERROR=ACTIVE_CONTROLLER_REQUIRED' >&2; return 155;
	}
	line="$(awk -F '\t' -v id="$account_id" '$1==id {print; exit}' "$TNA_DRIVE_REGISTRY_FILE")"
	[ -n "$line" ] || { echo 'TNA_DRIVE_ERROR=ACCOUNT_NOT_FOUND' >&2; return 152; }
	IFS=$'\t' read -r _ space_id role status username _ _ _ <<<"$line"
	[ "$role" = ordinary ] && { [ "$status" = active ] || [ "$status" = paused ]; } || {
		echo 'TNA_DRIVE_ERROR=ACCOUNT_ESCROW_NOT_REPLACEABLE' >&2; return 154;
	}
	tna_account_read_escrow "$account_id" "$space_id" "$username" include-pending
	tna_drive_txn_begin
	tna_account_write_escrow "$account_id"
	jq -e --arg account "$account_id" '.accountId==$account and (.envelopes|length)>=1' "$TNA_DRIVE_ESCROW_DIR/$account_id.json" >/dev/null || {
		tna_drive_txn_rollback; return 155;
	}
	tna_drive_txn_commit
	unset TNA_ACCOUNT_ESCROW_JSON
	printf 'TNA_DRIVE_ESCROW_REPLACED=1\nDRIVE_ACCOUNT_ID=%s\n' "$account_id"
}

tna_account_verify() {
  local username="${1:-}" line role status path port
  tna_drive_read_password
  tna_account_require_ready
  line="$(tna_drive_registry_find_user "$username" || true)"
  [ -n "$line" ] || { echo 'TNA_DRIVE_ERROR=ACCOUNT_NOT_FOUND' >&2; return 152; }
  IFS=$'\t' read -r _ _ role status _ _ _ _ <<<"$line"
  [ "$status" = active ] || { echo 'TNA_DRIVE_ERROR=ACCOUNT_NOT_ACTIVE' >&2; return 152; }
  path="$(tna_drive_account_path "$role" "$username")"
  port="$TNA_ACCOUNT_PORT"
  tna_drive_verify_login "$port" "$username" "$TNA_DRIVE_PASSWORD" "$path" success || { echo 'TNA_DRIVE_ERROR=PASSWORD_REJECTED' >&2; return 153; }
  unset TNA_DRIVE_PASSWORD
  echo 'TNA_DRIVE_ACCOUNT_LOGIN_OK'
}

tna_account_set_status() {
  local username="${1:-}" target="$2" line account_id role current
  tna_drive_prepare_base "$ROOT"
  tna_drive_lock
  tna_account_load_runtime
  line="$(tna_drive_registry_find_user "$username" || true)"
  [ -n "$line" ] || { echo 'TNA_DRIVE_ERROR=ACCOUNT_NOT_FOUND' >&2; return 152; }
  IFS=$'\t' read -r account_id _ role current _ _ _ _ <<<"$line"
  [ "$role" = ordinary ] || { echo 'TNA_DRIVE_ERROR=ADMIN_ACCOUNT_PROTECTED' >&2; return 154; }
  case "$target" in active|paused|revoked) ;; *) return 2;; esac
  case "$target:$current" in paused:active|active:paused|revoked:active|revoked:paused) ;; *) echo 'TNA_DRIVE_ERROR=ACCOUNT_STATE_TRANSITION_INVALID' >&2; return 154;; esac
  tna_drive_txn_begin
  if [ "$target" = revoked ]; then
    tna_drive_txn_track_escrow "$account_id"
    rm -f -- "$TNA_DRIVE_ESCROW_DIR/$account_id.json"
  fi
  awk -F '\t' -v OFS='\t' -v u="$username" -v s="$target" '$5==u {$4=s} {print}' "$TNA_DRIVE_REGISTRY_FILE" > "$TNA_DRIVE_REGISTRY_FILE.next"
  chmod 0600 "$TNA_DRIVE_REGISTRY_FILE.next" && mv -f -- "$TNA_DRIVE_REGISTRY_FILE.next" "$TNA_DRIVE_REGISTRY_FILE"
  if ! tna_account_apply; then tna_drive_txn_rollback; return 148; fi
  tna_drive_txn_commit
  printf 'TNA_DRIVE_ACCOUNT_STATUS=%s\nDRIVE_ACCOUNT_USERNAME=%s\n' "$target" "$username"
}

tna_account_list() {
  local account_id space_id role status username _ quota created
  printf '__TNA_DRIVE_ACCOUNT_LIST_BEGIN__\n'
  while IFS=$'\t' read -r account_id space_id role status username _ quota created; do
    printf 'ACCOUNT=%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$account_id" "$space_id" "$role" "$status" "$username" "$quota" "$created"
  done < "$TNA_DRIVE_REGISTRY_FILE"
  printf '__TNA_DRIVE_ACCOUNT_LIST_END__\n'
}

case "${1:-}" in
  register) [ "$#" -eq 5 ] || exit 2; tna_account_register "$2" "$3" "$4" "$5" ;;
  change-password) [ "$#" -eq 2 ] || exit 2; tna_account_change_password "$2" ;;
	replace-escrow) [ "$#" -eq 3 ] || exit 2; tna_account_replace_escrow "$2" "$3" ;;
  verify) [ "$#" -eq 2 ] || exit 2; tna_account_verify "$2" ;;
  list) [ "$#" -eq 1 ] || exit 2; tna_account_list ;;
  pause) [ "$#" -eq 2 ] || exit 2; tna_account_set_status "$2" paused ;;
  resume) [ "$#" -eq 2 ] || exit 2; tna_account_set_status "$2" active ;;
  revoke) [ "$#" -eq 2 ] || exit 2; tna_account_set_status "$2" revoked ;;
  *) echo 'usage: 30-copyparty-account.sh register USER auto|GIB ACCOUNT_ID SPACE_ID | change-password USER | replace-escrow REQUESTER_DEVICE_ID ACCOUNT_ID | verify USER | list | pause USER | resume USER | revoke USER' >&2; exit 2 ;;
esac
