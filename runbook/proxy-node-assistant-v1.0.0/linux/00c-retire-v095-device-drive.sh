#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

# One-time, fail-closed retirement for the over-scoped v0.9.5 device gate and
# private-drive experiment.  This script deliberately does not remove a whole
# TextNodeAssistant state directory, a whole authorized_keys file, any normal
# x-ui client, or either possible drive-data root.

MODE="${1:---apply}"
case "$MODE" in
  --apply|--status) ;;
  *) echo 'usage: 00c-retire-v095-device-drive.sh [--apply|--status]' >&2; exit 2 ;;
esac

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE_DIR=/etc/text-node-assistant
# v1.0.0 renamed the application state root.  A few v0.9.5 runs wrote their
# device/drive receipts there before the reset boundary was applied.  Never
# remove this directory wholesale: it also contains active public, DNS, and
# deployment state.  Only the exact, ownership-validated paths below are
# eligible for retirement.
CURRENT_STATE_DIR=/etc/proxy-runbook
ARCHIVE_ROOT=/root/.config/text-node-assistant/retired-v095-features
RETIREMENT_STATE="$ARCHIVE_ROOT/state.env"
LOCK_FILE=/run/lock/text-node-assistant-v095-feature-retirement.lock
DEVICE_REGISTRY="$STATE_DIR/device-registry.json"
CURRENT_DEVICE_REGISTRY="$CURRENT_STATE_DIR/device-registry.json"
CURRENT_DEVICE_LOCK=/run/lock/proxy-runbook-device-admission.lock
DRIVE_STATE="$STATE_DIR/private-drive.env"
DRIVE_CONFIG="$STATE_DIR/copyparty.conf"
DRIVE_ACCOUNTS="$STATE_DIR/drive-accounts.tsv"
DRIVE_ESCROW="$STATE_DIR/drive-credential-escrow"
DRIVE_PROGRAM_DIR=/opt/text-node-assistant/copyparty
DRIVE_RUNTIME_DIR=/var/lib/text-node-assistant/copyparty
DRIVE_LOG_DIR=/var/log/text-node-assistant/copyparty
DRIVE_LOCK=/var/lib/text-node-assistant/drive-transaction.lock
DRIVE_UNIT=/etc/systemd/system/text-node-assistant-copyparty.service
DRIVE_SERVICE=text-node-assistant-copyparty.service
NGINX_AVAILABLE=/etc/nginx/sites-available/tna-private-drive
NGINX_ENABLED=/etc/nginx/sites-enabled/tna-private-drive
DRIVE_CANDIDATE="$STATE_DIR/candidates/private-drive-production.conf"
DRIVE_CANDIDATE_SUM="$DRIVE_CANDIDATE.sha256"
# Companion names used by the short-lived v1 namespace migration.  These are
# intentionally separate from the active files in /etc/proxy-runbook; the
# retirement worker may touch them only after an old-drive marker is proven.
CURRENT_DRIVE_STATE="$CURRENT_STATE_DIR/private-drive.env"
CURRENT_DRIVE_CONFIG="$CURRENT_STATE_DIR/copyparty.conf"
CURRENT_DRIVE_ACCOUNTS="$CURRENT_STATE_DIR/drive-accounts.tsv"
CURRENT_DRIVE_ESCROW="$CURRENT_STATE_DIR/drive-credential-escrow"
CURRENT_DRIVE_LOCK=/var/lib/proxy-runbook/drive-transaction.lock
CURRENT_DRIVE_UNIT=/etc/systemd/system/proxy-runbook-copyparty.service
CURRENT_DRIVE_SERVICE=proxy-runbook-copyparty.service
CURRENT_DRIVE_CANDIDATE="$CURRENT_STATE_DIR/candidates/private-drive-production.conf"
CURRENT_DRIVE_CANDIDATE_SUM="$CURRENT_DRIVE_CANDIDATE.sha256"
NEW_DATA_ROOT=/srv/text-node-assistant/drive-data
LEGACY_DATA_ROOT=/srv/proxy-node-assistant/drive-data

WORK=''
ARCHIVE_PATH=''
DRIVE_OWNED=0
DEVICE_REGISTRY_OWNED=0
CURRENT_DEVICE_REGISTRY_OWNED=0
CURRENT_DRIVE_OWNED=0
NGINX_OWNED=0
CANDIDATE_OWNED=0
XUI_PRESENT=0
XUI_MANAGED_CLIENTS=0
XUI_GLOBAL_MANAGED_CLIENTS=0
AUTHORIZED_KEY_FILES=0
NGINX_CHANGED=0
CHANGE_COUNT=0
UNMANAGED_PRESERVED=0
declare -a XUI_UPDATED_IDS=()
declare -a CURRENT_DRIVE_TEMP_FILES=()
XUI_GLOBAL_CLIENTS_FILE=''
XUI_GLOBAL_MANAGED_FILE=''
XUI_GLOBAL_UNMANAGED_FILE=''
XUI_GLOBAL_UNMANAGED_IDENTITY_FILE=''
XUI_GLOBAL_EMAILS_FILE=''
XUI_GLOBAL_CURRENT_EMAILS_FILE=''
XUI_GLOBAL_DELETED_CLIENTS=0
XUI_GLOBAL_ALREADY_REMOVED=0
XUI_RESTARTED=0
XUI_CONFIG_PATH=/usr/local/x-ui/bin/config.json
XUI_RUNTIME_STALE=0

die() {
  printf 'TNA_V095_RETIREMENT_ERROR=%s\n' "$1" >&2
  exit "${2:-80}"
}

cleanup() {
  local rc=$?
  trap - EXIT
  if [ -n "$WORK" ]; then
    case "$WORK" in /tmp/tna-v095-retire.*) rm -rf -- "$WORK";; esac
  fi
  exit "$rc"
}
trap cleanup EXIT

[ "$(id -u)" -eq 0 ] || die ROOT_REQUIRED 2
command -v flock >/dev/null 2>&1 || die FLOCK_MISSING 2
command -v tar >/dev/null 2>&1 || die TAR_MISSING 2
command -v jq >/dev/null 2>&1 || die JQ_MISSING 2
exec 9>"$LOCK_FILE"
flock -x 9

WORK="$(mktemp -d /tmp/tna-v095-retire.XXXXXX)"
install -d -m 0700 "$WORK/archive/files" "$WORK/archive/evidence" \
  "$WORK/auth-original" "$WORK/auth-filtered" "$WORK/xui-original" "$WORK/xui-payload"
XUI_GLOBAL_CLIENTS_FILE="$WORK/xui-original/global-clients.json"
XUI_GLOBAL_MANAGED_FILE="$WORK/xui-original/global-managed-clients.json"
XUI_GLOBAL_UNMANAGED_FILE="$WORK/xui-original/global-unmanaged-clients.json"
XUI_GLOBAL_UNMANAGED_IDENTITY_FILE="$WORK/xui-original/global-unmanaged-identities.json"
XUI_GLOBAL_EMAILS_FILE="$WORK/xui-original/global-managed-emails.txt"
XUI_GLOBAL_CURRENT_EMAILS_FILE="$WORK/xui-original/current-global-managed-emails.txt"
: > "$WORK/evidence-authorized.tsv"
: > "$WORK/archive/evidence/removed-authorized-key-lines.txt"
: > "$WORK/archive/evidence/removed-xui-clients.jsonl"
: > "$WORK/archive/evidence/removed-xui-global-clients.jsonl"
: > "$WORK/archive/evidence/already-removed-xui-global-clients.txt"
: > "$WORK/archive/evidence/preserved-data-roots.txt"

file_has_marker() {
  local file="$1" marker="$2"
  [ -f "$file" ] && [ ! -L "$file" ] && grep -qF "$marker" "$file"
}

file_has_exact_line() {
  local file="$1" line="$2"
  [ -f "$file" ] && [ ! -L "$file" ] && grep -qxF "$line" "$file"
}

is_owned_device_registry() {
  local path="$1"
  [ -f "$path" ] && [ ! -L "$path" ] &&
    jq -e '(.version == 1 or .version == 2) and (.nodeId | type == "string") and (.devices | type == "array") and (.invites | type == "array")' \
      "$path" >/dev/null 2>&1
}

is_owned_drive_state() {
  local path="$1"
  file_has_exact_line "$path" 'PRIVATE_DRIVE_MODE=copyparty' &&
    grep -qxE 'PRIVATE_DRIVE_STATE_VERSION=[12]' "$path"
}

is_owned_drive_config() {
  file_has_marker "$1" '# TNA_MANAGED_COPYPARTY_V095'
}

is_owned_drive_unit() {
  file_has_marker "$1" '# TNA_MANAGED_COPYPARTY_SYSTEMD_V095'
}

is_owned_drive_temp() {
  local path="$1"
  # The glob is deliberately constrained to the current state directory and
  # the file must carry the same mode/version marker as the normal state file.
  case "$path" in
    "$CURRENT_STATE_DIR"/.private-drive.*) is_owned_drive_state "$path" ;;
    *) return 1 ;;
  esac
}

is_managed_authorized_key_line() {
  local line="${1:-}"
  [[ "$line" =~ [[:space:]](text-node-assistant-device|proxy-node-assistant-device):[^[:space:]]+[[:space:]]*$ ]]
}

is_xui_installed() {
  [ -x /usr/local/x-ui/x-ui ] || command -v x-ui >/dev/null 2>&1
}

validate_owned_state() {
  if [ -e "$DEVICE_REGISTRY" ] || [ -L "$DEVICE_REGISTRY" ]; then
    if is_owned_device_registry "$DEVICE_REGISTRY"; then
    DEVICE_REGISTRY_OWNED=1
    CHANGE_COUNT=$((CHANGE_COUNT + 1))
    else
      printf 'TNA_V095_RETIREMENT_UNMANAGED_PRESERVED=%s\n' "$DEVICE_REGISTRY" >&2
      UNMANAGED_PRESERVED=$((UNMANAGED_PRESERVED + 1))
    fi
  fi

  if [ -e "$CURRENT_DEVICE_REGISTRY" ] || [ -L "$CURRENT_DEVICE_REGISTRY" ]; then
    if is_owned_device_registry "$CURRENT_DEVICE_REGISTRY"; then
      CURRENT_DEVICE_REGISTRY_OWNED=1
      CHANGE_COUNT=$((CHANGE_COUNT + 1))
    else
      printf 'TNA_V095_RETIREMENT_UNMANAGED_PRESERVED=%s\n' "$CURRENT_DEVICE_REGISTRY" >&2
      UNMANAGED_PRESERVED=$((UNMANAGED_PRESERVED + 1))
    fi
  fi

  if file_has_exact_line "$DRIVE_STATE" 'PRIVATE_DRIVE_MODE=copyparty' &&
     grep -qxE 'PRIVATE_DRIVE_STATE_VERSION=[12]' "$DRIVE_STATE"; then
    DRIVE_OWNED=1
  fi
  file_has_marker "$DRIVE_CONFIG" '# TNA_MANAGED_COPYPARTY_V095' && DRIVE_OWNED=1
  file_has_marker "$DRIVE_UNIT" '# TNA_MANAGED_COPYPARTY_SYSTEMD_V095' && DRIVE_OWNED=1

  local path
  for path in "$DRIVE_STATE" "$DRIVE_CONFIG" "$DRIVE_ACCOUNTS" "$DRIVE_ESCROW" \
    "$DRIVE_PROGRAM_DIR" "$DRIVE_RUNTIME_DIR" "$DRIVE_LOG_DIR" "$DRIVE_UNIT"; do
    if { [ -e "$path" ] || [ -L "$path" ]; } && [ "$DRIVE_OWNED" -ne 1 ]; then
      printf 'TNA_V095_RETIREMENT_UNMANAGED_PRESERVED=%s\n' "$path" >&2
      UNMANAGED_PRESERVED=$((UNMANAGED_PRESERVED + 1))
    fi
  done
  if [ "$DRIVE_OWNED" -eq 1 ]; then
    CHANGE_COUNT=$((CHANGE_COUNT + 1))
  fi

  # The renamed v1 namespace can contain a stale v0.9.5 receipt even when
  # the active /etc/proxy-runbook/public.env and deployment files are valid.
  # Prove ownership independently for each marker; an unmarked companion is
  # reported and preserved rather than guessed at.
  local current_drive_found=0 current_path
  is_owned_drive_state "$CURRENT_DRIVE_STATE" && current_drive_found=1
  is_owned_drive_config "$CURRENT_DRIVE_CONFIG" && current_drive_found=1
  is_owned_drive_unit "$CURRENT_DRIVE_UNIT" && current_drive_found=1
  while IFS= read -r -d '' current_path; do
    if is_owned_drive_temp "$current_path"; then
      CURRENT_DRIVE_TEMP_FILES+=("$current_path")
      current_drive_found=1
    else
      printf 'TNA_V095_RETIREMENT_UNMANAGED_PRESERVED=%s\n' "$current_path" >&2
      UNMANAGED_PRESERVED=$((UNMANAGED_PRESERVED + 1))
    fi
  done < <(find "$CURRENT_STATE_DIR" -maxdepth 1 -type f -name '.private-drive.*' -print0 2>/dev/null || true)
  CURRENT_DRIVE_OWNED="$current_drive_found"
  if [ "$CURRENT_DRIVE_OWNED" -eq 1 ]; then
    CHANGE_COUNT=$((CHANGE_COUNT + 1))
  fi
  for current_path in "$CURRENT_DRIVE_STATE" "$CURRENT_DRIVE_CONFIG" "$CURRENT_DRIVE_ACCOUNTS" \
    "$CURRENT_DRIVE_ESCROW" "$CURRENT_DRIVE_LOCK" "$CURRENT_DRIVE_UNIT" \
    "$CURRENT_DRIVE_CANDIDATE" "$CURRENT_DRIVE_CANDIDATE_SUM"; do
    if { [ -e "$current_path" ] || [ -L "$current_path" ]; } && [ "$CURRENT_DRIVE_OWNED" -eq 0 ]; then
      printf 'TNA_V095_RETIREMENT_UNMANAGED_PRESERVED=%s\n' "$current_path" >&2
      UNMANAGED_PRESERVED=$((UNMANAGED_PRESERVED + 1))
    fi
  done

  if file_has_marker "$NGINX_AVAILABLE" '# TNA_MANAGED_COPYPARTY_NGINX_V095' ||
     file_has_marker "$NGINX_ENABLED" '# TNA_MANAGED_COPYPARTY_NGINX_V095'; then
    NGINX_OWNED=1
    CHANGE_COUNT=$((CHANGE_COUNT + 1))
  else
    local nginx_path
    for nginx_path in "$NGINX_AVAILABLE" "$NGINX_ENABLED"; do
      if [ -e "$nginx_path" ] || [ -L "$nginx_path" ]; then
        printf 'TNA_V095_RETIREMENT_UNMANAGED_PRESERVED=%s\n' "$nginx_path" >&2
        UNMANAGED_PRESERVED=$((UNMANAGED_PRESERVED + 1))
      fi
    done
  fi
  if file_has_marker "$DRIVE_CANDIDATE" '# TNA_MANAGED_COPYPARTY_NGINX_V095'; then
    CANDIDATE_OWNED=1
    CHANGE_COUNT=$((CHANGE_COUNT + 1))
  elif [ -e "$DRIVE_CANDIDATE" ] || [ -L "$DRIVE_CANDIDATE" ]; then
    printf 'TNA_V095_RETIREMENT_UNMANAGED_PRESERVED=%s\n' "$DRIVE_CANDIDATE" >&2
    UNMANAGED_PRESERVED=$((UNMANAGED_PRESERVED + 1))
  fi
}

collect_authorized_key_changes() {
  local user home path line index=0 original filtered removed
  while IFS=: read -r user _ _ _ _ home _; do
    [ -n "$user" ] && [ -n "$home" ] && [ "${home#/}" != "$home" ] && [ "$home" != / ] || continue
    path="${home%/}/.ssh/authorized_keys"
    [ -e "$path" ] || [ -L "$path" ] || continue
    if [ -L "$path" ]; then
      if grep -Eq '[[:space:]](text-node-assistant-device|proxy-node-assistant-device):[^[:space:]]+[[:space:]]*$' "$path" 2>/dev/null; then
        die MANAGED_AUTHORIZED_KEYS_SYMLINK_REFUSED
      fi
      continue
    fi
    [ -f "$path" ] || continue
    removed=0
    original="$WORK/auth-original/$index"
    filtered="$WORK/auth-filtered/$index"
    cp -a -- "$path" "$original"
    : > "$filtered"
    while IFS= read -r line || [ -n "$line" ]; do
      if is_managed_authorized_key_line "$line"; then
        printf '%s\t%s\t%s\n' "$user" "$path" "$line" >> "$WORK/archive/evidence/removed-authorized-key-lines.txt"
        removed=$((removed + 1))
      else
        printf '%s\n' "$line" >> "$filtered"
      fi
    done < "$path"
    if [ "$removed" -gt 0 ]; then
      printf '%s\t%s\t%s\t%s\n' "$index" "$user" "$path" "$filtered" >> "$WORK/evidence-authorized.tsv"
      AUTHORIZED_KEY_FILES=$((AUTHORIZED_KEY_FILES + 1))
      CHANGE_COUNT=$((CHANGE_COUNT + 1))
      index=$((index + 1))
    else
      rm -f -- "$original" "$filtered"
    fi
  done < /etc/passwd
}

# Keep every jq program single-quoted and pass data with --arg/--argjson.
# The previous implementation interpolated a multi-line shell variable into
# each jq invocation.  That made the jq source dependent on shell quoting and
# required an escaped jq id variable in one read-back filter; on some remote
# shells the resulting program was parsed differently (or failed before the
# API call).
# Repeating this short predicate deliberately keeps the program text literal,
# so a shell can never expand jq variables or inject whitespace into it.

xui_payload() {
  jq -c '
    def tna_managed_client:
      (((.comment // "") | test("^(tna|pna)-device:")) or
       ((.email // "") | test("^(tna|pna)-device:")));
    {enable,remark,listen,port,protocol,expiryTime,total,settings,streamSettings,sniffing,
     tag,allocate,subSortIndex,trafficReset,trafficResetDay,shareAddrStrategy,shareAddr}
    | .settings.clients |= map(select(tna_managed_client | not))
  ' "$1"
}

xui_original_payload() {
  jq -c '{enable,remark,listen,port,protocol,expiryTime,total,settings,streamSettings,sniffing,
          tag,allocate,subSortIndex,trafficReset,trafficResetDay,shareAddrStrategy,shareAddr}' "$1"
}

collect_xui_global_clients() {
  local list invalid_count duplicate_count managed_count
  list="$(xui_api_get '/panel/api/clients/list')" || die XUI_GLOBAL_CLIENT_LIST_FAILED
  jq -e '.success == true and (.obj | type == "array") and all(.obj[]; type == "object")' <<<"$list" >/dev/null || die XUI_GLOBAL_CLIENT_LIST_INVALID
  printf '%s\n' "$list" > "$XUI_GLOBAL_CLIENTS_FILE"

  # The delete endpoint addresses a client by email. Refuse malformed or
  # duplicate managed rows rather than guessing which database row to remove.
  invalid_count="$(jq '
    def is_managed:
      (((.comment // "") | if type == "string" then test("^(tna|pna)-device:") else false end) or
       ((.email // "") | if type == "string" then test("^(tna|pna)-device:") else false end));
    [.obj[] | select(is_managed) |
      select((.email | type) != "string" or (.email | length) == 0 or (.email | test("[\\r\\n\\t]")))] | length
  ' <<<"$list")"
  [ "$invalid_count" -eq 0 ] || die XUI_GLOBAL_CLIENT_EMAIL_MISSING

  duplicate_count="$(jq '
    def is_managed:
      (((.comment // "") | if type == "string" then test("^(tna|pna)-device:") else false end) or
       ((.email // "") | if type == "string" then test("^(tna|pna)-device:") else false end));
    [.obj[] | select(is_managed) | .email] |
      group_by(.) | map(select(length > 1)) | length
  ' <<<"$list")"
  [ "$duplicate_count" -eq 0 ] || die XUI_GLOBAL_CLIENT_EMAIL_DUPLICATE

  jq -c '
    def is_managed:
      (((.comment // "") | if type == "string" then test("^(tna|pna)-device:") else false end) or
       ((.email // "") | if type == "string" then test("^(tna|pna)-device:") else false end));
    [.obj[] | select(is_managed)]
  ' <<<"$list" > "$XUI_GLOBAL_MANAGED_FILE"
  jq -S -c '
    def is_managed:
      (((.comment // "") | if type == "string" then test("^(tna|pna)-device:") else false end) or
       ((.email // "") | if type == "string" then test("^(tna|pna)-device:") else false end));
    [.obj[] | select(is_managed | not)] | sort_by((.email // ""), (.id // 0))
  ' <<<"$list" > "$XUI_GLOBAL_UNMANAGED_FILE"
  jq -S -c '
    map({
      email:(if (.email | type) == "string" then .email else "" end),
      id:(.id // 0),
      inboundIds:(if (.inboundIds | type) == "array" then .inboundIds else [] end)
    }) | sort_by(.email, .id)
  ' "$XUI_GLOBAL_UNMANAGED_FILE" > "$XUI_GLOBAL_UNMANAGED_IDENTITY_FILE"
  jq -r '.[].email' "$XUI_GLOBAL_MANAGED_FILE" | sort -u > "$XUI_GLOBAL_EMAILS_FILE"
  managed_count="$(wc -l < "$XUI_GLOBAL_EMAILS_FILE")"
  XUI_GLOBAL_MANAGED_CLIENTS=$((managed_count + 0))
  if [ "$XUI_GLOBAL_MANAGED_CLIENTS" -gt 0 ]; then
    jq -c '.[]' "$XUI_GLOBAL_MANAGED_FILE" >> "$WORK/archive/evidence/removed-xui-global-clients.jsonl"
    CHANGE_COUNT=$((CHANGE_COUNT + 1))
  fi
  printf '%s\n' "$list" > "$WORK/archive/evidence/global-clients-original.json"
  cp -a -- "$XUI_GLOBAL_UNMANAGED_FILE" "$WORK/archive/evidence/global-clients-unmanaged-original.json"
  cp -a -- "$XUI_GLOBAL_UNMANAGED_IDENTITY_FILE" "$WORK/archive/evidence/global-clients-unmanaged-identities-original.json"
}
collect_xui_changes() {
  local list id object managed_count existing_token=''
  is_xui_installed || return 0
  XUI_PRESENT=1
  [ -r "$ROOT/linux/lib-xui-api.sh" ] || die XUI_HELPER_MISSING
  # shellcheck source=lib-xui-api.sh
  . "$ROOT/linux/lib-xui-api.sh"
  if [ -z "${XUI_API_TOKEN:-}" ]; then
    existing_token="$(xui_first_line /root/.config/text-node-assistant/XUI_API_TOKEN 2>/dev/null || true)"
    [ -n "$existing_token" ] || existing_token="$(xui_env_value /root/.config/text-node-assistant/HANDOFF-SECRETS.txt PANEL_API_TOKEN 2>/dev/null || true)"
    [ -n "$existing_token" ] || existing_token="$(xui_env_value /etc/x-ui/install-result.env XUI_API_TOKEN 2>/dev/null || true)"
    [ -z "$existing_token" ] || export XUI_API_TOKEN="$existing_token"
  fi
  export PNA_XUI_PUBLIC_FILE="$STATE_DIR/public.env"
  # The shared helper normally refreshes token caches.  Retirement is bounded
  # to old feature artifacts, so redirect those incidental writes to WORK.
  export PNA_XUI_HANDOFF_FILE="$WORK/xui-helper/HANDOFF-SECRETS.txt"
  export PNA_XUI_TOKEN_CACHE_FILE="$WORK/xui-helper/XUI_API_TOKEN"
  install -d -m 0700 "$WORK/xui-helper"
  xui_api_context >/dev/null 2>&1 || die XUI_API_UNAVAILABLE
  collect_xui_global_clients
  list="$(xui_api_get '/panel/api/inbounds/list')" || die XUI_INBOUND_LIST_FAILED
  jq -e '.success == true and (.obj | type == "array")' <<<"$list" >/dev/null || die XUI_INBOUND_LIST_INVALID
  while IFS= read -r id; do
    [[ "$id" =~ ^[0-9]+$ ]] || die XUI_INBOUND_ID_INVALID
    object="$(jq -c --argjson id "$id" '.obj[] | select(.id == $id)' <<<"$list")"
    managed_count="$(jq '
      def tna_managed_client:
        (((.comment // "") | test("^(tna|pna)-device:")) or
         ((.email // "") | test("^(tna|pna)-device:")));
      [.settings.clients[]? | select(tna_managed_client)] | length
    ' <<<"$object")"
    [ "$managed_count" -gt 0 ] || continue
    printf '%s\n' "$object" > "$WORK/xui-original/$id.json"
    xui_payload "$WORK/xui-original/$id.json" > "$WORK/xui-payload/$id.json"
    jq -c '
      def tna_managed_client:
        (((.comment // "") | test("^(tna|pna)-device:")) or
         ((.email // "") | test("^(tna|pna)-device:")));
      {inboundId:.id,remark:(.remark // ""),managedClients:[.settings.clients[]? | select(tna_managed_client)]}
    ' <<<"$object" >> "$WORK/archive/evidence/removed-xui-clients.jsonl"
    XUI_MANAGED_CLIENTS=$((XUI_MANAGED_CLIENTS + managed_count))
    CHANGE_COUNT=$((CHANGE_COUNT + 1))
  done < <(jq -r '.obj[]?.id' <<<"$list")
}

copy_for_archive() {
  local path="$1"
  [ -e "$path" ] || [ -L "$path" ] || return 0
  (cd / && cp -a --parents -- "${path#/}" "$WORK/archive/files/")
}

create_archive() {
  local stamp path
  install -d -o root -g root -m 0700 "$ARCHIVE_ROOT"
  if [ "$DEVICE_REGISTRY_OWNED" -eq 1 ]; then copy_for_archive "$DEVICE_REGISTRY"; fi
  if [ "$CURRENT_DEVICE_REGISTRY_OWNED" -eq 1 ]; then copy_for_archive "$CURRENT_DEVICE_REGISTRY"; fi
  if [ "$DRIVE_OWNED" -eq 1 ]; then
    copy_for_archive "$DRIVE_STATE"
    copy_for_archive "$DRIVE_CONFIG"
    copy_for_archive "$DRIVE_ACCOUNTS"
    copy_for_archive "$DRIVE_ESCROW"
    copy_for_archive "$DRIVE_PROGRAM_DIR"
    copy_for_archive "$DRIVE_RUNTIME_DIR"
    copy_for_archive "$DRIVE_LOG_DIR"
    copy_for_archive "$DRIVE_UNIT"
    copy_for_archive "$DRIVE_CANDIDATE"
    copy_for_archive "$DRIVE_CANDIDATE_SUM"
  fi
  if [ "$CURRENT_DRIVE_OWNED" -eq 1 ]; then
    # Archive only the exact current-namespace companions.  The parent
    # /etc/proxy-runbook directory also holds active deployment state and is
    # intentionally never copied or removed wholesale.
    copy_for_archive "$CURRENT_DRIVE_STATE"
    copy_for_archive "$CURRENT_DRIVE_CONFIG"
    copy_for_archive "$CURRENT_DRIVE_ACCOUNTS"
    copy_for_archive "$CURRENT_DRIVE_ESCROW"
    copy_for_archive "$CURRENT_DRIVE_LOCK"
    copy_for_archive "$CURRENT_DRIVE_UNIT"
    copy_for_archive "$CURRENT_DRIVE_CANDIDATE"
    copy_for_archive "$CURRENT_DRIVE_CANDIDATE_SUM"
    for path in "${CURRENT_DRIVE_TEMP_FILES[@]}"; do copy_for_archive "$path"; done
  fi
  if [ "$NGINX_OWNED" -eq 1 ]; then
    copy_for_archive "$NGINX_AVAILABLE"
    copy_for_archive "$NGINX_ENABLED"
  fi
  if [ "$CANDIDATE_OWNED" -eq 1 ]; then
    copy_for_archive "$DRIVE_CANDIDATE"
    copy_for_archive "$DRIVE_CANDIDATE_SUM"
  fi
  {
    printf 'PRESERVED=%s\n' "$NEW_DATA_ROOT"
    printf 'PRESERVED=%s\n' "$LEGACY_DATA_ROOT"
    printf 'EXCLUDED_FROM_ARCHIVE=drive file contents (data roots remain in place)\n'
  } > "$WORK/archive/evidence/preserved-data-roots.txt"
  {
    echo 'RETIREMENT_SCHEMA_VERSION=1'
    echo 'SOURCE_FEATURE_LINE=complex-v0.9.5'
    printf 'DEVICE_REGISTRY_OWNED=%s\n' "$DEVICE_REGISTRY_OWNED"
    printf 'CURRENT_DEVICE_REGISTRY_OWNED=%s\n' "$CURRENT_DEVICE_REGISTRY_OWNED"
    printf 'DRIVE_OWNED=%s\n' "$DRIVE_OWNED"
    printf 'CURRENT_DRIVE_OWNED=%s\n' "$CURRENT_DRIVE_OWNED"
    printf 'NGINX_OWNED=%s\n' "$NGINX_OWNED"
    printf 'CANDIDATE_OWNED=%s\n' "$CANDIDATE_OWNED"
    printf 'XUI_MANAGED_CLIENTS=%s\n' "$XUI_MANAGED_CLIENTS"
    printf 'XUI_GLOBAL_MANAGED_CLIENTS=%s\n' "$XUI_GLOBAL_MANAGED_CLIENTS"
    printf 'XUI_GLOBAL_DELETED_CLIENTS=%s\n' "$XUI_GLOBAL_DELETED_CLIENTS"
    printf 'XUI_GLOBAL_ALREADY_ABSENT=%s\n' "$XUI_GLOBAL_ALREADY_REMOVED"
    printf 'XUI_RUNTIME_STALE=%s\n' "$XUI_RUNTIME_STALE"
    printf 'XUI_RESTARTED=%s\n' "$XUI_RESTARTED"
    printf 'AUTHORIZED_KEY_FILES=%s\n' "$AUTHORIZED_KEY_FILES"
    printf 'CREATED_AT=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  } > "$WORK/archive/evidence/manifest.env"
  chmod -R go-rwx "$WORK/archive"
  stamp="$(date -u +%Y%m%d-%H%M%S)"
  ARCHIVE_PATH="$ARCHIVE_ROOT/v095-feature-retirement-${stamp}-$$.tar.gz"
  tar -C "$WORK/archive" -czf "$ARCHIVE_PATH" .
  chown root:root "$ARCHIVE_PATH"
  chmod 0600 "$ARCHIVE_PATH"
  [ "$(stat -c '%U:%G:%a' "$ARCHIVE_PATH")" = 'root:root:600' ] || die ARCHIVE_PERMISSIONS_INVALID
}

xui_update() {
  local id="$1" payload="$2" response
  response="$(xui_api_post_json "/panel/api/inbounds/update/${id}" "$payload")" || return 1
  jq -e '.success == true' <<<"$response" >/dev/null
}

xui_delete_global_client() {
  local email="$1" encoded response
  [ -n "$email" ] || return 1
  case "$email" in
    *$'\r'*|*$'\n'*|*$'\t'*) return 1 ;;
  esac
  encoded="$(jq -nr --arg email "$email" '$email | @uri')" || return 1
  [ -n "$encoded" ] || return 1
  response="$(xui_auth_curl -X POST "${XUI_BASE}/panel/api/clients/del/${encoded}")" || return 1
  jq -e '(.success == true) or (.success == "true")' <<<"$response" >/dev/null
}

verify_global_snapshot_before_delete() {
  local current current_emails current_identity unknown duplicate invalid
  current="$(xui_api_get '/panel/api/clients/list')" || return 1
  jq -e '.success == true and (.obj | type == "array") and all(.obj[]; type == "object")' <<<"$current" >/dev/null || return 1
  current_emails="$XUI_GLOBAL_CURRENT_EMAILS_FILE"
  current_identity="$WORK/xui-original/current-global-unmanaged-identities.json"
  invalid="$(jq '
    def is_managed:
      (((.comment // "") | if type == "string" then test("^(tna|pna)-device:") else false end) or
       ((.email // "") | if type == "string" then test("^(tna|pna)-device:") else false end));
    [.obj[] | select(is_managed) |
      select((.email | type) != "string" or (.email | length) == 0 or (.email | test("[\\r\\n\\t]")))] | length
  ' <<<"$current")"
  [ "$invalid" -eq 0 ] || return 1
  duplicate="$(jq '
    def is_managed:
      (((.comment // "") | if type == "string" then test("^(tna|pna)-device:") else false end) or
       ((.email // "") | if type == "string" then test("^(tna|pna)-device:") else false end));
    [.obj[] | select(is_managed) | .email] |
      group_by(.) | map(select(length > 1)) | length
  ' <<<"$current")"
  [ "$duplicate" -eq 0 ] || return 1
  jq -r '
    def is_managed:
      (((.comment // "") | if type == "string" then test("^(tna|pna)-device:") else false end) or
       ((.email // "") | if type == "string" then test("^(tna|pna)-device:") else false end));
    [.obj[] | select(is_managed) | .email] | sort | .[]
  ' <<<"$current" > "$current_emails" || return 1
  # An inbound update may remove a client from the global table as a side
  # effect.  That is safe; reject only a newly-created/foreign managed row.
  unknown="$(comm -23 "$current_emails" "$XUI_GLOBAL_EMAILS_FILE" || true)"
  [ -z "$unknown" ] || return 1
  jq -S -c '
    def is_managed:
      (((.comment // "") | if type == "string" then test("^(tna|pna)-device:") else false end) or
       ((.email // "") | if type == "string" then test("^(tna|pna)-device:") else false end));
    [.obj[] | select(is_managed | not) |
      {email:(if (.email | type) == "string" then .email else "" end),
       id:(.id // 0),
       inboundIds:(if (.inboundIds | type) == "array" then .inboundIds else [] end)}] |
      sort_by(.email, .id)
  ' <<<"$current" > "$current_identity" || return 1
  cmp -s -- "$current_identity" "$XUI_GLOBAL_UNMANAGED_IDENTITY_FILE"
}

apply_xui_global_deletions() {
  local email response latest current_present
  [ "$XUI_GLOBAL_MANAGED_CLIENTS" -gt 0 ] || return 0
  verify_global_snapshot_before_delete || die XUI_GLOBAL_CLIENTS_CHANGED_DURING_RETIREMENT
  while IFS= read -r email; do
    [ -n "$email" ] || continue
    if xui_delete_global_client "$email"; then
      XUI_GLOBAL_DELETED_CLIENTS=$((XUI_GLOBAL_DELETED_CLIENTS + 1))
      continue
    fi
    # The preceding inbound update can race with the global delete.  Re-read
    # once and treat an already absent row as a successful no-op; any other
    # API failure remains fail-closed.
    latest="$(xui_api_get '/panel/api/clients/list')" || die XUI_GLOBAL_CLIENT_DELETE_FAILED
    jq -e '.success == true and (.obj | type == "array") and all(.obj[]; type == "object")' <<<"$latest" >/dev/null || die XUI_GLOBAL_CLIENT_DELETE_FAILED
    current_present="$(jq -r --arg email "$email" '
      def is_managed:
        (((.comment // "") | if type == "string" then test("^(tna|pna)-device:") else false end) or
         ((.email // "") | if type == "string" then test("^(tna|pna)-device:") else false end));
      [.obj[] | select(is_managed) | select(.email == $email)] | length
    ' <<<"$latest")"
    if [ "$current_present" -eq 0 ]; then
      printf '%s\n' "$email" >> "$WORK/archive/evidence/already-removed-xui-global-clients.txt"
      XUI_GLOBAL_ALREADY_REMOVED=$((XUI_GLOBAL_ALREADY_REMOVED + 1))
    else
      die XUI_GLOBAL_CLIENT_DELETE_FAILED
    fi
  done < "$XUI_GLOBAL_CURRENT_EMAILS_FILE"
}

# 3x-ui stores its generated Xray child configuration separately from the
# panel database.  API edits can therefore leave a deleted device client live
# until x-ui is restarted.  Count only the explicit managed-client markers in
# that generated file; ordinary client rows and all other runtime state are
# left untouched.
xui_runtime_marker_count() {
  local count='0'
  [ -f "$XUI_CONFIG_PATH" ] || { printf '0\n'; return 0; }
  count="$(grep -Eoc '(tna|pna)-device:' "$XUI_CONFIG_PATH" 2>/dev/null || true)"
  [[ "$count" =~ ^[0-9]+$ ]] || count=0
  printf '%s\n' "$count"
}

verify_xui_runtime_config() {
  local strict="${1:-0}" count='0'
  if [ ! -f "$XUI_CONFIG_PATH" ]; then
    if [ "$strict" -eq 1 ]; then
      die XUI_RUNTIME_CONFIG_MISSING
    fi
    printf 'XUI_RUNTIME_CONFIG=NOT_PRESENT\n'
    return 0
  fi
  count="$(xui_runtime_marker_count)"
  if [ "$count" -gt 0 ]; then
    die XUI_RUNTIME_MANAGED_CLIENT_STILL_PRESENT
  fi
  printf 'XUI_RUNTIME_MANAGED_CLIENTS=0\n'
}

# An x-ui API update changes the database first; depending on the 3x-ui build,
# the running Xray child may keep the old generated config until the panel is
# restarted.  Treat a restart as part of the retirement transaction, but only
# when an inbound or global client was actually changed.  If the restart or
# the post-restart readback fails, die before touching the SSH keys/drive so
# the outer install transaction can restore its captured baseline.
restart_xui_after_changes() {
  local changed=0
  if [ "$XUI_MANAGED_CLIENTS" -gt 0 ] || [ "$XUI_GLOBAL_DELETED_CLIENTS" -gt 0 ] || [ "$XUI_RUNTIME_STALE" -eq 1 ]; then
    changed=1
  fi
  if [ "$changed" -eq 0 ]; then
    printf 'XUI_RESTART_SKIPPED=NO_XUI_CHANGES\n'
    return 0
  fi
  [ "$XUI_PRESENT" -eq 1 ] || die XUI_RESTART_REQUIRED_BUT_XUI_MISSING
  command -v systemctl >/dev/null 2>&1 || die XUI_RESTART_SYSTEMCTL_MISSING
  systemctl restart x-ui >/dev/null 2>&1 || die XUI_RESTART_FAILED
  for _ in $(seq 1 30); do
    systemctl is-active --quiet x-ui 2>/dev/null && break
    sleep 1
  done
  systemctl is-active --quiet x-ui 2>/dev/null || die XUI_RESTART_NOT_ACTIVE
  XUI_RESTARTED=1
  printf 'XUI_RESTARTED=1\n'
  for _ in $(seq 1 30); do
    if [ -f "$XUI_CONFIG_PATH" ] && [ "$(xui_runtime_marker_count)" -eq 0 ]; then
      verify_xui_runtime_config 1
      return 0
    fi
    sleep 1
  done
  verify_xui_runtime_config 1
}

verify_global_clients_retired() {
  local current managed current_identity
  current="$(xui_api_get '/panel/api/clients/list')" || die XUI_GLOBAL_FINAL_READBACK_FAILED
  jq -e '.success == true and (.obj | type == "array") and all(.obj[]; type == "object")' <<<"$current" >/dev/null || die XUI_GLOBAL_FINAL_READBACK_INVALID
  managed="$(jq '
    def is_managed:
      (((.comment // "") | if type == "string" then test("^(tna|pna)-device:") else false end) or
       ((.email // "") | if type == "string" then test("^(tna|pna)-device:") else false end));
    [.obj[] | select(is_managed)] | length
  ' <<<"$current")"
  [ "$managed" -eq 0 ] || die XUI_GLOBAL_CLIENT_STILL_PRESENT
  current_identity="$WORK/xui-original/final-global-unmanaged-identities.json"
  jq -S -c '
    def is_managed:
      (((.comment // "") | if type == "string" then test("^(tna|pna)-device:") else false end) or
       ((.email // "") | if type == "string" then test("^(tna|pna)-device:") else false end));
    [.obj[] | select(is_managed | not) |
      {email:(if (.email | type) == "string" then .email else "" end),
       id:(.id // 0),
       inboundIds:(if (.inboundIds | type) == "array" then .inboundIds else [] end)}] |
      sort_by(.email, .id)
  ' <<<"$current" > "$current_identity" || die XUI_GLOBAL_UNMANAGED_READBACK_MISMATCH
  cmp -s -- "$current_identity" "$XUI_GLOBAL_UNMANAGED_IDENTITY_FILE" || die XUI_GLOBAL_UNMANAGED_READBACK_MISMATCH
  printf 'XUI_GLOBAL_MANAGED_READBACK=%s\n' "$managed"
}

rollback_xui() {
  local id original payload failed=0
  for id in "${XUI_UPDATED_IDS[@]}"; do
    original="$WORK/xui-original/$id.json"
    payload="$(xui_original_payload "$original")"
    xui_update "$id" "$payload" || failed=1
  done
  return "$failed"
}

verify_unmanaged_clients_unchanged() {
  local id="$1" expected current
  expected="$(jq -S -c '
    def tna_managed_client:
      (((.comment // "") | test("^(tna|pna)-device:")) or
       ((.email // "") | test("^(tna|pna)-device:")));
    [.settings.clients[]? | select(tna_managed_client | not)]
  ' "$WORK/xui-original/$id.json")"
  current="$(xui_api_get '/panel/api/inbounds/list')" || return 1
  jq -e '.success == true and (.obj | type == "array")' <<<"$current" >/dev/null || return 1
  jq -S -c --argjson id "$id" '
    def tna_managed_client:
      (((.comment // "") | test("^(tna|pna)-device:")) or
       ((.email // "") | test("^(tna|pna)-device:")));
    [.obj[] | select(.id == $id) | .settings.clients[]? | select(tna_managed_client | not)]
  ' <<<"$current" | grep -Fxq "$expected"
}

apply_xui_changes() {
  local file id payload
  [ "$XUI_MANAGED_CLIENTS" -gt 0 ] || return 0
  for file in "$WORK/xui-payload"/*.json; do
    [ -e "$file" ] || continue
    id="$(basename "$file" .json)"
    payload="$(cat "$file")"
    # Include the current inbound in rollback even if the API applies the
    # update but loses or mangles its success response.
    XUI_UPDATED_IDS+=("$id")
    if ! xui_update "$id" "$payload"; then
      rollback_xui || true
      die XUI_CLIENT_RETIREMENT_FAILED
    fi
    if ! verify_unmanaged_clients_unchanged "$id"; then
      rollback_xui || true
      die XUI_UNMANAGED_CLIENT_READBACK_MISMATCH
    fi
  done
}

apply_authorized_key_changes() {
  local index user path filtered tmp
  while IFS=$'\t' read -r index user path filtered; do
    [ -n "$path" ] || continue
    [ -f "$path" ] && [ ! -L "$path" ] || die AUTHORIZED_KEYS_CHANGED_DURING_RETIREMENT
    cmp -s -- "$path" "$WORK/auth-original/$index" || die AUTHORIZED_KEYS_CHANGED_DURING_RETIREMENT
    tmp="$(mktemp "$(dirname "$path")/.authorized_keys.tna-retire.XXXXXX")"
    cat "$filtered" > "$tmp"
    chown --reference="$path" "$tmp"
    chmod --reference="$path" "$tmp"
    mv -f -- "$tmp" "$path"
  done < "$WORK/evidence-authorized.tsv"
}

remove_managed_nginx() {
  local enabled_owned=0 target=''
  if [ "$NGINX_OWNED" -eq 1 ]; then
    if [ -L "$NGINX_ENABLED" ]; then
      target="$(readlink -f "$NGINX_ENABLED" 2>/dev/null || true)"
      [ "$target" = "$NGINX_AVAILABLE" ] &&
        file_has_marker "$NGINX_AVAILABLE" '# TNA_MANAGED_COPYPARTY_NGINX_V095' && enabled_owned=1
    elif file_has_marker "$NGINX_ENABLED" '# TNA_MANAGED_COPYPARTY_NGINX_V095'; then
      enabled_owned=1
    fi
    [ "$enabled_owned" -eq 0 ] || rm -f -- "$NGINX_ENABLED"
    file_has_marker "$NGINX_AVAILABLE" '# TNA_MANAGED_COPYPARTY_NGINX_V095' && rm -f -- "$NGINX_AVAILABLE"
    NGINX_CHANGED=1
  fi
  if [ "$CANDIDATE_OWNED" -eq 1 ]; then
    rm -f -- "$DRIVE_CANDIDATE" "$DRIVE_CANDIDATE_SUM"
  fi
}

remove_managed_drive() {
  local unit_owned=0 config_owned=0
  [ "$DRIVE_OWNED" -eq 1 ] || return 0
  file_has_marker "$DRIVE_UNIT" '# TNA_MANAGED_COPYPARTY_SYSTEMD_V095' && unit_owned=1
  file_has_marker "$DRIVE_CONFIG" '# TNA_MANAGED_COPYPARTY_V095' && config_owned=1
  if [ "$unit_owned" -eq 1 ]; then
    systemctl disable --now "$DRIVE_SERVICE" >/dev/null 2>&1 || true
    systemctl is-active --quiet "$DRIVE_SERVICE" 2>/dev/null && die COPYPARTY_SERVICE_DID_NOT_STOP
    rm -f -- "$DRIVE_UNIT"
  elif systemctl is-active --quiet "$DRIVE_SERVICE" 2>/dev/null; then
    die UNMANAGED_COPYPARTY_SERVICE_ACTIVE
  fi
  [ "$config_owned" -eq 0 ] || rm -f -- "$DRIVE_CONFIG"
  rm -f -- "$DRIVE_STATE" "$DRIVE_ACCOUNTS" "$DRIVE_LOCK"
  rm -rf -- "$DRIVE_ESCROW"
  if [ -d "$DRIVE_PROGRAM_DIR" ] && [ ! -L "$DRIVE_PROGRAM_DIR" ]; then
    rm -f -- "$DRIVE_PROGRAM_DIR/copyparty-sfx.py"
    find "$DRIVE_PROGRAM_DIR" -depth -type d -empty -delete 2>/dev/null || true
  fi
  if [ -d "$DRIVE_RUNTIME_DIR" ] && [ ! -L "$DRIVE_RUNTIME_DIR" ]; then rm -rf -- "$DRIVE_RUNTIME_DIR"; fi
  if [ -d "$DRIVE_LOG_DIR" ] && [ ! -L "$DRIVE_LOG_DIR" ]; then rm -rf -- "$DRIVE_LOG_DIR"; fi
  systemctl daemon-reload
}

remove_current_managed_drive() {
  local unit_owned=0 config_owned=0 path current_temp
  [ "$CURRENT_DRIVE_OWNED" -eq 1 ] || return 0
  is_owned_drive_unit "$CURRENT_DRIVE_UNIT" && unit_owned=1
  is_owned_drive_config "$CURRENT_DRIVE_CONFIG" && config_owned=1
  if [ "$unit_owned" -eq 1 ]; then
    systemctl disable --now "$CURRENT_DRIVE_SERVICE" >/dev/null 2>&1 || true
    systemctl is-active --quiet "$CURRENT_DRIVE_SERVICE" 2>/dev/null && die CURRENT_COPYPARTY_SERVICE_DID_NOT_STOP
    rm -f -- "$CURRENT_DRIVE_UNIT"
  elif systemctl is-active --quiet "$CURRENT_DRIVE_SERVICE" 2>/dev/null; then
    # A live service without the v0.9.5 ownership marker is never guessed at.
    die UNMANAGED_CURRENT_COPYPARTY_SERVICE_ACTIVE
  fi
  [ "$config_owned" -eq 0 ] || rm -f -- "$CURRENT_DRIVE_CONFIG"
  # These are exact v0.9.5 companion names in the renamed state root.  Do not
  # recurse through /etc/proxy-runbook or remove its active deployment files.
  rm -f -- "$CURRENT_DRIVE_STATE" "$CURRENT_DRIVE_ACCOUNTS" "$CURRENT_DRIVE_LOCK"
  if [ -d "$CURRENT_DRIVE_ESCROW" ] && [ ! -L "$CURRENT_DRIVE_ESCROW" ]; then
    rm -rf -- "$CURRENT_DRIVE_ESCROW"
  elif [ -L "$CURRENT_DRIVE_ESCROW" ]; then
    rm -f -- "$CURRENT_DRIVE_ESCROW"
  fi
  for current_temp in "${CURRENT_DRIVE_TEMP_FILES[@]}"; do
    is_owned_drive_temp "$current_temp" || die CURRENT_COPYPARTY_TEMP_OWNERSHIP_CHANGED
    rm -f -- "$current_temp"
  done
  rm -f -- "$CURRENT_DRIVE_CANDIDATE" "$CURRENT_DRIVE_CANDIDATE_SUM"
  systemctl daemon-reload
}

remove_device_registry() {
  [ "$DEVICE_REGISTRY_OWNED" -eq 0 ] || rm -f -- "$DEVICE_REGISTRY"
  [ "$CURRENT_DEVICE_REGISTRY_OWNED" -eq 0 ] || rm -f -- "$CURRENT_DEVICE_REGISTRY"
  rm -f -- /run/lock/text-node-assistant-device-admission.lock
  [ "$CURRENT_DEVICE_REGISTRY_OWNED" -eq 0 ] || rm -f -- "$CURRENT_DEVICE_LOCK"
}

verify_retirement() {
  local path list managed remaining=0
  if [ "$DEVICE_REGISTRY_OWNED" -eq 1 ]; then
    [ ! -e "$DEVICE_REGISTRY" ] && [ ! -L "$DEVICE_REGISTRY" ] || die DEVICE_REGISTRY_STILL_PRESENT
  fi
  if [ "$CURRENT_DEVICE_REGISTRY_OWNED" -eq 1 ]; then
    [ ! -e "$CURRENT_DEVICE_REGISTRY" ] && [ ! -L "$CURRENT_DEVICE_REGISTRY" ] || die CURRENT_DEVICE_REGISTRY_STILL_PRESENT
  fi
  while IFS=: read -r _ _ _ _ _ path _; do
    [ -n "$path" ] && [ "${path#/}" != "$path" ] && [ "$path" != / ] || continue
    path="${path%/}/.ssh/authorized_keys"
    [ -f "$path" ] || continue
    grep -Eq '[[:space:]](text-node-assistant-device|proxy-node-assistant-device):[^[:space:]]+[[:space:]]*$' "$path" && remaining=$((remaining + 1))
  done < /etc/passwd
  [ "$remaining" -eq 0 ] || die MANAGED_AUTHORIZED_KEY_STILL_PRESENT
  if [ "$XUI_PRESENT" -eq 1 ]; then
    list="$(xui_api_get '/panel/api/inbounds/list')" || die XUI_FINAL_READBACK_FAILED
    jq -e '.success == true and (.obj | type == "array")' <<<"$list" >/dev/null || die XUI_FINAL_READBACK_INVALID
    managed="$(jq '
      def tna_managed_client:
        (((.comment // "") | test("^(tna|pna)-device:")) or
         ((.email // "") | test("^(tna|pna)-device:")));
      [.obj[]?.settings.clients[]? | select(tna_managed_client)] | length
    ' <<<"$list")"
    [ "$managed" -eq 0 ] || die XUI_MANAGED_CLIENT_STILL_PRESENT
    verify_global_clients_retired
  fi
  if [ "$DRIVE_OWNED" -eq 1 ]; then
    systemctl is-active --quiet "$DRIVE_SERVICE" 2>/dev/null && die COPYPARTY_SERVICE_STILL_ACTIVE
    file_has_marker "$DRIVE_CONFIG" '# TNA_MANAGED_COPYPARTY_V095' && die COPYPARTY_CONFIG_STILL_PRESENT
    file_has_marker "$DRIVE_UNIT" '# TNA_MANAGED_COPYPARTY_SYSTEMD_V095' && die COPYPARTY_UNIT_STILL_PRESENT
  fi
  if [ "$CURRENT_DRIVE_OWNED" -eq 1 ]; then
    systemctl is-active --quiet "$CURRENT_DRIVE_SERVICE" 2>/dev/null && die CURRENT_COPYPARTY_SERVICE_STILL_ACTIVE
    is_owned_drive_state "$CURRENT_DRIVE_STATE" && die CURRENT_COPYPARTY_STATE_STILL_PRESENT
    is_owned_drive_config "$CURRENT_DRIVE_CONFIG" && die CURRENT_COPYPARTY_CONFIG_STILL_PRESENT
    is_owned_drive_unit "$CURRENT_DRIVE_UNIT" && die CURRENT_COPYPARTY_UNIT_STILL_PRESENT
    for path in "${CURRENT_DRIVE_TEMP_FILES[@]}"; do
      is_owned_drive_temp "$path" && die CURRENT_COPYPARTY_TEMP_STILL_PRESENT
    done
  fi
  if [ "$NGINX_OWNED" -eq 1 ]; then
    file_has_marker "$NGINX_AVAILABLE" '# TNA_MANAGED_COPYPARTY_NGINX_V095' && die COPYPARTY_NGINX_STILL_PRESENT
    file_has_marker "$NGINX_ENABLED" '# TNA_MANAGED_COPYPARTY_NGINX_V095' && die COPYPARTY_NGINX_STILL_PRESENT
  fi
  if [ "$CANDIDATE_OWNED" -eq 1 ]; then
    file_has_marker "$DRIVE_CANDIDATE" '# TNA_MANAGED_COPYPARTY_NGINX_V095' && die COPYPARTY_CANDIDATE_STILL_PRESENT
  fi
  [ ! -e "$NEW_DATA_ROOT" ] || printf 'TNA_V095_RETIREMENT_DATA_PRESERVED=%s\n' "$NEW_DATA_ROOT"
  [ ! -e "$LEGACY_DATA_ROOT" ] || printf 'TNA_V095_RETIREMENT_DATA_PRESERVED=%s\n' "$LEGACY_DATA_ROOT"
}

write_retirement_state() {
  local tmp
  install -d -o root -g root -m 0700 "$ARCHIVE_ROOT"
  tmp="$(mktemp "$ARCHIVE_ROOT/.state.XXXXXX")"
  {
    echo 'RETIREMENT_SCHEMA_VERSION=1'
    echo 'RETIREMENT_STATUS=COMPLETE'
    printf 'LAST_ARCHIVE=%s\n' "$ARCHIVE_PATH"
    printf 'COMPLETED_AT=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo 'DRIVE_DATA_POLICY=PRESERVED_IN_PLACE'
  } > "$tmp"
  chown root:root "$tmp"
  chmod 0600 "$tmp"
  mv -f -- "$tmp" "$RETIREMENT_STATE"
}

validate_owned_state
collect_authorized_key_changes
if [ "$MODE" = --apply ]; then
  collect_xui_changes
  # A previous run may already have removed the managed rows from the panel
  # database while leaving the generated Xray child config untouched.  Treat
  # that drift as a repairable change so the early ALREADY_CLEAN path cannot
  # silently preserve a live device gate.
  if [ "$XUI_PRESENT" -eq 1 ] && [ "$(xui_runtime_marker_count)" -gt 0 ]; then
    XUI_RUNTIME_STALE=1
    CHANGE_COUNT=$((CHANGE_COUNT + 1))
    printf 'XUI_RUNTIME_STALE_MARKERS=%s\n' "$(xui_runtime_marker_count)"
  fi
fi

if [ "$MODE" = --status ]; then
  printf 'TNA_V095_FEATURE_RETIREMENT_STATUS=INSPECTED\n'
  printf 'DEVICE_REGISTRY_OWNED=%s\nCURRENT_DEVICE_REGISTRY_OWNED=%s\nDRIVE_OWNED=%s\nCURRENT_DRIVE_OWNED=%s\nNGINX_OWNED=%s\nCANDIDATE_OWNED=%s\nAUTHORIZED_KEY_FILES=%s\n' \
    "$DEVICE_REGISTRY_OWNED" "$CURRENT_DEVICE_REGISTRY_OWNED" "$DRIVE_OWNED" "$CURRENT_DRIVE_OWNED" "$NGINX_OWNED" "$CANDIDATE_OWNED" "$AUTHORIZED_KEY_FILES"
  printf 'XUI_CLIENT_SCAN=NOT_PERFORMED_READ_ONLY_MODE\nXUI_GLOBAL_CLIENT_SCAN=NOT_PERFORMED_READ_ONLY_MODE\nUNMANAGED_PRESERVED=%s\n' "$UNMANAGED_PRESERVED"
  exit 0
fi

if [ "$CHANGE_COUNT" -eq 0 ] && [ "$XUI_MANAGED_CLIENTS" -eq 0 ]; then
  echo 'TNA_V095_FEATURE_RETIREMENT=ALREADY_CLEAN'
  [ ! -r "$RETIREMENT_STATE" ] || sed -n 's/^LAST_ARCHIVE=/LAST_ARCHIVE=/p' "$RETIREMENT_STATE"
  exit 0
fi

create_archive
apply_xui_changes
apply_xui_global_deletions
restart_xui_after_changes
apply_authorized_key_changes
remove_managed_nginx
remove_managed_drive
remove_current_managed_drive
remove_device_registry
if [ "$NGINX_CHANGED" -eq 1 ] && command -v nginx >/dev/null 2>&1; then
  nginx -t || die NGINX_CONFIG_TEST_FAILED_AFTER_MANAGED_SITE_REMOVAL
  systemctl reload nginx
fi
verify_retirement
write_retirement_state

echo 'TNA_V095_FEATURE_RETIREMENT=COMPLETE'
printf 'RETIREMENT_ARCHIVE=%s\n' "$ARCHIVE_PATH"
printf 'DEVICE_REGISTRY_REMOVED=%s\nCURRENT_DEVICE_REGISTRY_REMOVED=%s\nDRIVE_RUNTIME_REMOVED=%s\nCURRENT_DRIVE_RUNTIME_REMOVED=%s\n' \
  "$DEVICE_REGISTRY_OWNED" "$CURRENT_DEVICE_REGISTRY_OWNED" "$DRIVE_OWNED" "$CURRENT_DRIVE_OWNED"
printf 'XUI_DEVICE_CLIENTS_REMOVED=%s\nXUI_GLOBAL_DEVICE_CLIENTS_REMOVED=%s\nXUI_GLOBAL_DEVICE_CLIENTS_ALREADY_ABSENT=%s\nAUTHORIZED_KEY_FILES_UPDATED=%s\n' "$XUI_MANAGED_CLIENTS" "$XUI_GLOBAL_DELETED_CLIENTS" "$XUI_GLOBAL_ALREADY_REMOVED" "$AUTHORIZED_KEY_FILES"
echo 'DRIVE_DATA_PRESERVED=1'
