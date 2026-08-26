#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/linux/lib-xui-api.sh"
. "$ROOT/linux/lib-drive.sh"

COMMAND="${1:-status}"
shift || true
STATE_DIR="/etc/text-node-assistant"
REGISTRY="$STATE_DIR/device-registry.json"
DRIVE_ESCROW_DIR="$STATE_DIR/drive-credential-escrow"
LOCK_FILE="/run/lock/text-node-assistant-device-admission.lock"
TX_DIR=''
TX_ACTIVE=0
TX_ACTION=''
TX_DEVICE_ID=''
TX_AUTH_PATH=''
TX_AUTH_EXISTED=0

die() {
  printf 'TNA_DEVICE_ERROR=%s\n' "$1" >&2
  exit "${2:-1}"
}

[ "$(id -u)" -eq 0 ] || die ROOT_REQUIRED 2
command -v jq >/dev/null 2>&1 || die JQ_MISSING 2
command -v python3 >/dev/null 2>&1 || die PYTHON3_MISSING 2
command -v flock >/dev/null 2>&1 || die FLOCK_MISSING 2
xui_api_context || die XUI_API_UNAVAILABLE 61
install -d -m 700 "$STATE_DIR"
exec 9>"$LOCK_FILE"
flock -x 9

node_id() {
  local id
  id="$(bash "$ROOT/linux/23-node-identity.sh" --show 2>/dev/null | sed -n 's/^NODE_ID=//p' | sed -n '1p')"
  # v0.9.5 must be able to inspect nodes created by the v0.8.x/PNA line.
  # The registry is deliberately not rewritten during a read-only status
  # request; accepting both prefixes keeps existing admissions usable while
  # new enrollments continue to use the current TNA identity format.
  [[ "$id" =~ ^(tna|pna)-node-[0-9a-f]{32}$ ]] || die NODE_IDENTITY_NOT_INITIALIZED 62
  printf '%s' "$id"
}

init_registry() {
  if [ -s "$REGISTRY" ]; then
    if jq -e '.version == 1 and (.nodeId | type == "string") and (.devices | type == "array") and (.invites | type == "array")' "$REGISTRY" >/dev/null; then
      local migrated
      migrated="$(mktemp "$STATE_DIR/.device-registry-v2.XXXXXX")"
      jq '.version=2 | .invites |= map(select((.used // false)==true))' "$REGISTRY" > "$migrated" || { rm -f "$migrated"; die REGISTRY_MIGRATION_FAILED 62; }
      chmod 600 "$migrated"
      mv -f -- "$migrated" "$REGISTRY"
    fi
    jq -e '.version == 2 and (.nodeId | type == "string") and (.devices | type == "array") and (.invites | type == "array")' "$REGISTRY" >/dev/null || die REGISTRY_INVALID 62
    [ "$(jq -r '.nodeId' "$REGISTRY")" = "$(node_id)" ] || die REGISTRY_NODE_ID_MISMATCH 62
    return
  fi
  local tmp
  tmp="$(mktemp "$STATE_DIR/.device-registry.XXXXXX")"
  jq -nc --arg node "$(node_id)" '{version:2,nodeId:$node,devices:[],invites:[]}' > "$tmp"
  chmod 600 "$tmp"
  mv -f -- "$tmp" "$REGISTRY"
}

write_registry() {
  local filter="$1"; shift
  local tmp
  tmp="$(mktemp "$STATE_DIR/.device-registry.XXXXXX")"
  jq "$@" "$filter" "$REGISTRY" > "$tmp" || { rm -f "$tmp"; die REGISTRY_UPDATE_FAILED 63; }
  jq -e '.version == 2 and (.devices | type == "array") and (.invites | type == "array")' "$tmp" >/dev/null || { rm -f "$tmp"; die REGISTRY_UPDATE_INVALID 63; }
  chmod 600 "$tmp"
  mv -f -- "$tmp" "$REGISTRY"
}

validate_label() {
  local pattern='^[A-Za-z0-9._ -]+$'
  [ "${#1}" -ge 1 ] && [ "${#1}" -le 64 ] && [[ "$1" =~ $pattern ]]
}

validate_role() { [ "$1" = controller ] || [ "$1" = traffic-only ]; }

validate_ssh_user() { [[ "$1" =~ ^[A-Za-z_][A-Za-z0-9_.-]*$ ]] && getent passwd "$1" >/dev/null; }

authorized_keys_path() {
  local user="$1" home
  validate_ssh_user "$user" || return 1
  home="$(getent passwd "$user" | cut -d: -f6)"
  [ -n "$home" ] && [ "${home#/}" != "$home" ] && [ "$home" != / ] || return 1
  printf '%s/.ssh/authorized_keys\n' "${home%/}"
}

device_id_from_public() {
  python3 - "$1" <<'PY'
import base64,hashlib,re,sys
value=sys.argv[1]
match=re.fullmatch(r'(?P<prefix>tna|pna)-ed25519:(?P<key>[A-Za-z0-9_-]{43})', value)
if not match:
    raise SystemExit(1)
prefix=match.group('prefix')
raw=base64.urlsafe_b64decode(match.group('key')+'=')
if len(raw) != 32:
    raise SystemExit(1)
print(prefix+'-device-'+base64.b32encode(hashlib.sha256(raw).digest()[:16]).decode().rstrip('=').lower())
PY
}

normalize_ssh_public_key() {
  local key_type key_blob extra
  read -r key_type key_blob extra <<<"${1:-}"
  [ "$key_type" = ssh-ed25519 ] || return 1
  [[ "$key_blob" =~ ^[A-Za-z0-9+/]{68}$ ]] || return 1
  printf '%s %s\n' "$key_type" "$key_blob"
}

verify_enrollment_signature() {
  local node="$1" nonce="$2" device_id="$3" public="$4" label="$5" role="$6" encryption_public="$7" ssh_user="$8" ssh_public="$9" signature="${10}"
  local verify_dir public_der
  [[ "$signature" =~ ^[A-Za-z0-9_-]{86}$ ]] || die SIGNATURE_INVALID 71
  verify_dir="$(mktemp -d /tmp/tna-device-verify.XXXXXX)"
  trap 'rm -rf -- "$verify_dir"' RETURN
  python3 - "$public" "$signature" "$verify_dir/public.pem" "$verify_dir/signature.bin" <<'PY'
import base64,re,sys
public,signature,pem_path,sig_path=sys.argv[1:]
if not re.fullmatch(r'(?:tna|pna)-ed25519:[A-Za-z0-9_-]{43}', public):
    raise SystemExit(1)
raw=base64.urlsafe_b64decode(public.split(':',1)[1]+'=')
sig=base64.urlsafe_b64decode(signature+'==')
if len(raw)!=32 or len(sig)!=64:
    raise SystemExit(1)
# RFC 8410 SubjectPublicKeyInfo prefix for Ed25519 followed by the raw key.
der=bytes.fromhex('302a300506032b6570032100')+raw
pem=base64.b64encode(der).decode()
with open(pem_path,'w',encoding='ascii',newline='\n') as handle:
    handle.write('-----BEGIN PUBLIC KEY-----\n'+pem+'\n-----END PUBLIC KEY-----\n')
with open(sig_path,'wb') as handle:
    handle.write(sig)
PY
  printf 'TNA-DEVICE-ENROLL-V2\nNODE_ID=%s\nNONCE=%s\nDEVICE_ID=%s\nPUBLIC_KEY=%s\nLABEL=%s\nROLE=%s\nENCRYPTION_PUBLIC_KEY=%s\nSSH_LOGIN_USER=%s\nSSH_PUBLIC_KEY=%s\n' \
    "$node" "$nonce" "$device_id" "$public" "$label" "$role" "$encryption_public" "$ssh_user" "$ssh_public" > "$verify_dir/message.bin"
  openssl pkeyutl -verify -pubin -inkey "$verify_dir/public.pem" -rawin -in "$verify_dir/message.bin" -sigfile "$verify_dir/signature.bin" >/dev/null 2>&1 || die SIGNATURE_INVALID 71
  rm -rf -- "$verify_dir"
  trap - RETURN
}

verify_controller_encryption_signature() {
	local node="$1" device_id="$2" public="$3" encryption_public="$4" signature="$5" verify_dir
	[[ "$signature" =~ ^[A-Za-z0-9_-]{86}$ ]] || die SIGNATURE_INVALID 78
	verify_dir="$(mktemp -d /tmp/tna-controller-encryption-verify.XXXXXX)"
	trap 'rm -rf -- "$verify_dir"' RETURN
	python3 - "$public" "$signature" "$verify_dir/public.pem" "$verify_dir/signature.bin" <<'PY'
import base64,re,sys
public,signature,pem_path,sig_path=sys.argv[1:]
if not re.fullmatch(r'(?:tna|pna)-ed25519:[A-Za-z0-9_-]{43}', public): raise SystemExit(1)
raw=base64.urlsafe_b64decode(public.split(':',1)[1]+'=')
sig=base64.urlsafe_b64decode(signature+'==')
if len(raw)!=32 or len(sig)!=64: raise SystemExit(1)
der=bytes.fromhex('302a300506032b6570032100')+raw
pem=base64.b64encode(der).decode()
with open(pem_path,'w',encoding='ascii',newline='\n') as handle:
    handle.write('-----BEGIN PUBLIC KEY-----\n'+pem+'\n-----END PUBLIC KEY-----\n')
with open(sig_path,'wb') as handle: handle.write(sig)
PY
	printf 'TNA-CONTROLLER-ENCRYPTION-KEY-V1\nNODE_ID=%s\nDEVICE_ID=%s\nENCRYPTION_PUBLIC_KEY=%s\n' \
		"$node" "$device_id" "$encryption_public" > "$verify_dir/message.bin"
	openssl pkeyutl -verify -pubin -inkey "$verify_dir/public.pem" -rawin -in "$verify_dir/message.bin" -sigfile "$verify_dir/signature.bin" >/dev/null 2>&1 || die SIGNATURE_INVALID 78
	rm -rf -- "$verify_dir"
	trap - RETURN
}

read_enrollment_input() {
  IFS= read -r INPUT_NONCE || true
  IFS= read -r INPUT_PUBLIC || true
  IFS= read -r INPUT_LABEL || true
	IFS= read -r INPUT_ROLE || true
	IFS= read -r INPUT_ENCRYPTION_PUBLIC || true
	IFS= read -r INPUT_SSH_USER || true
	IFS= read -r INPUT_SSH_PUBLIC || true
	IFS= read -r INPUT_SIGNATURE || true
  [ -n "${INPUT_PUBLIC:-}" ] || die PUBLIC_KEY_MISSING 64
  DEVICE_ID="$(device_id_from_public "$INPUT_PUBLIC")" || die PUBLIC_KEY_INVALID 64
  validate_label "${INPUT_LABEL:-}" || die LABEL_INVALID 64
  validate_role "${INPUT_ROLE:-}" || die ROLE_INVALID 64
  [[ "${INPUT_ENCRYPTION_PUBLIC:-}" =~ ^tna-x25519:[A-Za-z0-9_-]{43}$ ]] || die ENCRYPTION_PUBLIC_KEY_INVALID 64
  validate_ssh_user "${INPUT_SSH_USER:-}" || die SSH_LOGIN_USER_INVALID 64
  INPUT_SSH_PUBLIC="$(normalize_ssh_public_key "${INPUT_SSH_PUBLIC:-}")" || die SSH_PUBLIC_KEY_INVALID 64
}

snapshot_authorized_keys() {
  local user="$1" path
  path="$(authorized_keys_path "$user")" || die SSH_LOGIN_USER_INVALID 65
  if [ -n "$TX_AUTH_PATH" ]; then [ "$TX_AUTH_PATH" = "$path" ] || die MULTIPLE_AUTHORIZED_KEYS_IN_TRANSACTION 65; return; fi
  TX_AUTH_PATH="$path"
  if [ -f "$path" ]; then
    cp -a "$path" "$TX_DIR/authorized_keys"
    TX_AUTH_EXISTED=1
  else
    TX_AUTH_EXISTED=0
  fi
}

install_device_ssh_key() {
  local device_id="$1" public_key="$2" role="$3" ssh_user="$4" mode="${5:-active}" nonce_hash="${6:-}" marker="text-node-assistant-device:${1}" tmp line drive_port authorized_keys command_prefix='' primary_group
  authorized_keys="$(authorized_keys_path "$ssh_user")" || die SSH_LOGIN_USER_INVALID 65
  primary_group="$(id -gn "$ssh_user")"
  snapshot_authorized_keys "$ssh_user"
  install -d -o "$ssh_user" -g "$primary_group" -m 700 "$(dirname "$authorized_keys")"
  touch "$authorized_keys"; chown "$ssh_user:$primary_group" "$authorized_keys"; chmod 600 "$authorized_keys"
  grep -Fq "$marker" "$authorized_keys" && remove_device_ssh_key "$device_id" "$ssh_user"
  if [ "$mode" = pending ]; then
    [[ "$nonce_hash" =~ ^[0-9a-f]{64}$ ]] || die INVITE_HASH_INVALID 65
    [ "$ssh_user" = root ] || command_prefix='sudo -n '
    line="restrict,command=\"${command_prefix}$ROOT/linux/26-device-admission.sh claim-forced $device_id $nonce_hash\" $public_key $marker"
  elif [ "$role" = controller ]; then
    line="$public_key $marker"
  else
    drive_port="$(sed -n 's/^COPYPARTY_LOOPBACK_PORT=//p' "$STATE_DIR/private-drive.env" 2>/dev/null | sed -n '1p')"
    [[ "$drive_port" =~ ^39[0-9]{3}$ ]] || die DRIVE_LOOPBACK_PORT_MISSING 65
    [ "$ssh_user" = root ] || command_prefix='sudo -n '
    line="restrict,port-forwarding,command=\"${command_prefix}$ROOT/linux/26-device-admission.sh traffic-forced $device_id\",permitopen=\"127.0.0.1:$drive_port\" $public_key $marker"
  fi
  tmp="$(mktemp "$(dirname "$authorized_keys")/.authorized_keys.XXXXXX")"
  cat "$authorized_keys" > "$tmp"
  printf '%s\n' "$line" >> "$tmp"
  chown "$ssh_user:$primary_group" "$tmp"
  chmod 600 "$tmp"
  mv -f -- "$tmp" "$authorized_keys"
}

remove_device_ssh_key() {
  local device_id="$1" ssh_user="$2" marker="text-node-assistant-device:${1}" tmp authorized_keys primary_group
  authorized_keys="$(authorized_keys_path "$ssh_user")" || die SSH_LOGIN_USER_INVALID 65
  primary_group="$(id -gn "$ssh_user")"
  snapshot_authorized_keys "$ssh_user"
  [ -f "$authorized_keys" ] || return 0
  tmp="$(mktemp "$(dirname "$authorized_keys")/.authorized_keys.XXXXXX")"
  grep -Fv "$marker" "$authorized_keys" > "$tmp" || true
  chown "$ssh_user:$primary_group" "$tmp"
  chmod 600 "$tmp"
  mv -f -- "$tmp" "$authorized_keys"
}

list_inbounds() { xui_api_get '/panel/api/inbounds/list'; }
get_reality() { list_inbounds | jq -c '.obj[]? | select(.port==443 and .protocol=="vless" and .streamSettings.security=="reality")' | sed -n '1p'; }
get_xhttp() { list_inbounds | jq -c '.obj[]? | select((.remark=="tna-cdn-xhttp" or .remark=="pna-cdn-xhttp") and .protocol=="vless" and .streamSettings.network=="xhttp")' | sed -n '1p'; }
get_by_id() { list_inbounds | jq -c --argjson id "$1" '.obj[]? | select(.id==$id)' | sed -n '1p'; }

payload_with_client() {
  local object="$1" client="$2"
  jq -c --argjson client "$client" '
    {enable,remark,listen,port,protocol,expiryTime,total,settings,streamSettings,sniffing,
     tag,allocate,subSortIndex,trafficReset,trafficResetDay,shareAddrStrategy,shareAddr}
    | .settings.clients += [$client]
  ' <<< "$object"
}

payload_set_client_enabled() {
  local object="$1" device_id="$2" enabled="$3"
  jq -c --arg marker "tna-device:${device_id}" --argjson enabled "$enabled" '
    {enable,remark,listen,port,protocol,expiryTime,total,settings,streamSettings,sniffing,
     tag,allocate,subSortIndex,trafficReset,trafficResetDay,shareAddrStrategy,shareAddr}
    | .settings.clients |= map(if (.comment // "") == $marker then .enable=$enabled else . end)
  ' <<< "$object"
}

payload_delete_client() {
  local object="$1" device_id="$2"
  jq -c --arg marker "tna-device:${device_id}" '
    {enable,remark,listen,port,protocol,expiryTime,total,settings,streamSettings,sniffing,
     tag,allocate,subSortIndex,trafficReset,trafficResetDay,shareAddrStrategy,shareAddr}
    | .settings.clients |= map(select((.comment // "") != $marker))
  ' <<< "$object"
}

update_inbound() {
  local id="$1" payload="$2" response
  response="$(xui_api_post_json "/panel/api/inbounds/update/${id}" "$payload")"
  jq -e '.success == true' <<< "$response" >/dev/null
}

rollback_inbounds() {
  local file id failed=0
  for file in "$TX_DIR"/*.json; do
    [ -e "$file" ] || continue
    [ "$(basename "$file")" != registry.json ] || continue
    id="$(jq -r '.id' "$file")"
    update_inbound "$id" "$(jq -c '{enable,remark,listen,port,protocol,expiryTime,total,settings,streamSettings,sniffing,tag,allocate,subSortIndex,trafficReset,trafficResetDay,shareAddrStrategy,shareAddr}' "$file")" || failed=1
  done
  return "$failed"
}

begin_transaction() {
  [ "$TX_ACTIVE" -eq 0 ] || die TRANSACTION_ALREADY_ACTIVE 63
  TX_ACTION="${1:-unknown}"
  TX_DEVICE_ID="${2:-}"
  TX_DIR="$(mktemp -d /tmp/tna-device-tx.XXXXXX)"
  cp -a "$REGISTRY" "$TX_DIR/registry.json"
  if [ -d "$DRIVE_ESCROW_DIR" ]; then cp -a "$DRIVE_ESCROW_DIR" "$TX_DIR/drive-credential-escrow"; fi
  TX_AUTH_PATH=''
  TX_AUTH_EXISTED=0
  TX_ACTIVE=1
}

commit_transaction() {
  TX_ACTIVE=0
  TX_ACTION=''
  TX_DEVICE_ID=''
  TX_AUTH_PATH=''
  TX_AUTH_EXISTED=0
  case "$TX_DIR" in /tmp/tna-device-tx.*) rm -rf -- "$TX_DIR";; *) die TRANSACTION_DIRECTORY_INVALID 63;; esac
  TX_DIR=''
}

transaction_exit() {
  local rc="$1" rollback_failed=0 tmp
  trap - EXIT
  if [ "$TX_ACTIVE" -eq 1 ]; then
    rollback_inbounds || rollback_failed=1
    cp -a "$TX_DIR/registry.json" "$REGISTRY" 2>/dev/null || rollback_failed=1
    if [ -d "$TX_DIR/drive-credential-escrow" ]; then
      rm -rf -- "$DRIVE_ESCROW_DIR" 2>/dev/null || rollback_failed=1
      cp -a "$TX_DIR/drive-credential-escrow" "$DRIVE_ESCROW_DIR" 2>/dev/null || rollback_failed=1
    fi
    if [ -n "$TX_AUTH_PATH" ]; then
      if [ "$TX_AUTH_EXISTED" -eq 1 ]; then
        install -d -m 700 "$(dirname "$TX_AUTH_PATH")"
        cp -a "$TX_DIR/authorized_keys" "$TX_AUTH_PATH" 2>/dev/null || rollback_failed=1
        chmod 600 "$TX_AUTH_PATH" 2>/dev/null || rollback_failed=1
      else
        rm -f -- "$TX_AUTH_PATH" 2>/dev/null || rollback_failed=1
      fi
    fi
    if [ "$rollback_failed" -eq 1 ] && [ "$TX_ACTION" = revoke ] && [ -n "$TX_DEVICE_ID" ] && [ -s "$REGISTRY" ]; then
      tmp="$(mktemp "$STATE_DIR/.device-registry-partial.XXXXXX")"
      if jq --arg id "$TX_DEVICE_ID" --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        '(.devices[] | select(.deviceId==$id) | .status)="REVOCATION_PARTIAL" | (.devices[] | select(.deviceId==$id) | .updatedAt)=$now' \
        "$REGISTRY" > "$tmp"; then
        chmod 600 "$tmp"
        mv -f -- "$tmp" "$REGISTRY"
      else
        rm -f -- "$tmp"
      fi
      echo 'TNA_DEVICE_REVOCATION_PARTIAL=1' >&2
    elif [ "$rollback_failed" -eq 1 ]; then
      echo 'TNA_DEVICE_TRANSACTION_PARTIAL=1' >&2
    else
      echo 'TNA_DEVICE_TRANSACTION_ROLLED_BACK=1' >&2
    fi
    case "$TX_DIR" in /tmp/tna-device-tx.*) rm -rf -- "$TX_DIR";; esac
  fi
  exit "$rc"
}

trap 'transaction_exit "$?"' EXIT

apply_new_clients() {
  local device_id="$1" uuid="$2" sub_id="$3" enabled="${4:-true}" reality xhttp object id client payload now found=0
  reality="$(get_reality)"
  xhttp="$(get_xhttp)"
  for object in "$reality" "$xhttp"; do
    [ -n "$object" ] || continue
    found=1
    id="$(jq -r '.id' <<< "$object")"
    cp -a /dev/null "$TX_DIR/${id}.json"
    printf '%s\n' "$object" > "$TX_DIR/${id}.json"
    jq -e --arg marker "tna-device:${device_id}" 'all(.settings.clients[]?; (.comment // "") != $marker)' <<< "$object" >/dev/null || die DEVICE_CLIENT_ALREADY_EXISTS 65
    if [ "$(jq -r '.streamSettings.security // ""' <<< "$object")" = reality ]; then
      client="$(jq -nc --arg uuid "$uuid" --arg sub "$sub_id" --arg marker "tna-device:${device_id}" --argjson enabled "$enabled" '{id:$uuid,email:$marker,flow:"xtls-rprx-vision",limitIp:0,totalGB:0,expiryTime:0,enable:$enabled,tgId:0,subId:$sub,comment:$marker}')"
    else
      client="$(jq -nc --arg uuid "$uuid" --arg sub "$sub_id" --arg marker "tna-device:${device_id}" --argjson enabled "$enabled" '{id:$uuid,email:$marker,flow:"",limitIp:0,totalGB:0,expiryTime:0,enable:$enabled,tgId:0,subId:$sub,comment:$marker}')"
    fi
    payload="$(payload_with_client "$object" "$client")"
    update_inbound "$id" "$payload" || die XUI_CLIENT_UPDATE_FAILED 66
    now="$(get_by_id "$id")"
    jq -e --arg uuid "$uuid" --arg marker "tna-device:${device_id}" --argjson enabled "$enabled" 'any(.settings.clients[]?; .id==$uuid and (.comment // "")==$marker and .enable==$enabled)' <<< "$now" >/dev/null || die XUI_CLIENT_READBACK_FAILED 66
  done
  [ "$found" -eq 1 ] || die NO_MANAGED_PROXY_INBOUND 65
}

set_device_enabled() {
  local device_id="$1" enabled="$2" object id payload now found=0 public role ssh_user
  begin_transaction "$([ "$enabled" = true ] && echo resume || echo pause)" "$device_id"
  for object in "$(get_reality)" "$(get_xhttp)"; do
    [ -n "$object" ] || continue
    if ! jq -e --arg marker "tna-device:${device_id}" 'any(.settings.clients[]?; (.comment // "")==$marker)' <<< "$object" >/dev/null; then continue; fi
    found=1
    id="$(jq -r '.id' <<< "$object")"
    printf '%s\n' "$object" > "$TX_DIR/${id}.json"
    payload="$(payload_set_client_enabled "$object" "$device_id" "$enabled")"
    update_inbound "$id" "$payload" || die XUI_CLIENT_UPDATE_FAILED 66
    now="$(get_by_id "$id")"
    jq -e --arg marker "tna-device:${device_id}" --argjson enabled "$enabled" 'any(.settings.clients[]?; (.comment // "")==$marker and .enable==$enabled)' <<< "$now" >/dev/null || die XUI_CLIENT_READBACK_FAILED 66
  done
  [ "$found" -eq 1 ] || die DEVICE_CLIENT_MISSING 66
  public="$(jq -r --arg id "$device_id" '.devices[] | select(.deviceId==$id) | .sshPublicKey' "$REGISTRY")"
  role="$(jq -r --arg id "$device_id" '.devices[] | select(.deviceId==$id) | .role' "$REGISTRY")"
  ssh_user="$(jq -r --arg id "$device_id" '.devices[] | select(.deviceId==$id) | .sshUser' "$REGISTRY")"
  if [ "$enabled" = true ]; then install_device_ssh_key "$device_id" "$public" "$role" "$ssh_user" active; else remove_device_ssh_key "$device_id" "$ssh_user"; fi
  write_registry '(.devices[] | select(.deviceId==$id) | .status)=$status | (.devices[] | select(.deviceId==$id) | .updatedAt)=$now' \
    --arg id "$device_id" --arg status "$([ "$enabled" = true ] && echo active || echo paused)" --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  commit_transaction
}

delete_device_clients() {
  local device_id="$1" object id payload now invite_hash ssh_user role escrow tmp
  invite_hash="$(jq -r --arg id "$device_id" '.devices[]? | select(.deviceId==$id) | .inviteNonceSha256 // empty' "$REGISTRY")"
  ssh_user="$(jq -r --arg id "$device_id" '.devices[]? | select(.deviceId==$id) | .sshUser' "$REGISTRY")"
  role="$(jq -r --arg id "$device_id" '.devices[]? | select(.deviceId==$id) | .role' "$REGISTRY")"
  begin_transaction revoke "$device_id"
  for object in "$(get_reality)" "$(get_xhttp)"; do
    [ -n "$object" ] || continue
    if ! jq -e --arg marker "tna-device:${device_id}" 'any(.settings.clients[]?; (.comment // "")==$marker)' <<< "$object" >/dev/null; then continue; fi
    id="$(jq -r '.id' <<< "$object")"
    printf '%s\n' "$object" > "$TX_DIR/${id}.json"
    payload="$(payload_delete_client "$object" "$device_id")"
    update_inbound "$id" "$payload" || die XUI_CLIENT_DELETE_FAILED 67
    now="$(get_by_id "$id")"
    jq -e --arg marker "tna-device:${device_id}" 'all(.settings.clients[]?; (.comment // "") != $marker)' <<< "$now" >/dev/null || die XUI_CLIENT_DELETE_READBACK_FAILED 67
  done
  remove_device_ssh_key "$device_id" "$ssh_user"
  if [ "$role" = controller ] && [ -d "$DRIVE_ESCROW_DIR" ]; then
    for escrow in "$DRIVE_ESCROW_DIR"/tna-account-*.json; do
      [ -e "$escrow" ] || continue
      tmp="$(mktemp "$DRIVE_ESCROW_DIR/.escrow-prune.XXXXXX")"
      jq --arg id "$device_id" '.envelopes |= map(select(.deviceId!=$id))' "$escrow" > "$tmp" || { rm -f -- "$tmp"; die ESCROW_ENVELOPE_PRUNE_FAILED 67; }
      jq -e '.envelopes|length>=1' "$tmp" >/dev/null || { rm -f -- "$tmp"; die LAST_ESCROW_CONTROLLER_PROTECTED 67; }
      chmod 600 "$tmp"; chown root:root "$tmp"; mv -f -- "$tmp" "$escrow"
    done
  fi
  write_registry '(.devices[] | select(.deviceId==$id) | .status)="revoked" | (.devices[] | select(.deviceId==$id) | .updatedAt)=$now' \
    --arg id "$device_id" --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  if [[ "$invite_hash" =~ ^[0-9a-f]{64}$ ]]; then
    write_registry '(.invites[] | select(.nonceSha256==$hash and .used==false)) |= del(.reservedDeviceId,.reservedAt)' --arg hash "$invite_hash"
  fi
  commit_transaction
}

register_device() {
  local public="$1" label="$2" role="$3" device_id="$4" encryption_public="$5" ssh_user="$6" ssh_public="$7" invite_index="${8:-}" uuid sub_id now invite_hash
  jq -e --arg id "$device_id" 'all(.devices[]?; .deviceId != $id)' "$REGISTRY" >/dev/null || die DEVICE_ALREADY_REGISTERED 68
  uuid="$(xui_new_uuid)"
  sub_id="$(openssl rand -hex 16)"
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  begin_transaction enroll "$device_id"
  if [ -n "$invite_index" ]; then
    apply_new_clients "$device_id" "$uuid" "$sub_id" false
    invite_hash="$(jq -r --argjson index "$invite_index" '.invites[$index].nonceSha256' "$REGISTRY")"
    install_device_ssh_key "$device_id" "$ssh_public" "$role" "$ssh_user" pending "$invite_hash"
  else
    apply_new_clients "$device_id" "$uuid" "$sub_id" true
    install_device_ssh_key "$device_id" "$ssh_public" "$role" "$ssh_user" active
  fi
  if [ -n "$invite_index" ]; then
    write_registry '.devices += [{deviceId:$id,publicKey:$public,encryptionPublicKey:$encryptionPublic,sshUser:$sshUser,sshPublicKey:$sshPublic,label:$display,role:$role,status:"pending-verification",vlessUuid:$uuid,subId:$sub,inviteNonceSha256:$inviteHash,createdAt:$now,updatedAt:$now}] | (.invites[$index].reservedDeviceId)=$id | (.invites[$index].reservedAt)=$now' \
      --arg id "$device_id" --arg public "$public" --arg encryptionPublic "$encryption_public" --arg sshUser "$ssh_user" --arg sshPublic "$ssh_public" --arg display "$label" --arg role "$role" --arg uuid "$uuid" --arg sub "$sub_id" --arg inviteHash "$invite_hash" --arg now "$now" --argjson index "$invite_index"
  else
    write_registry '.devices += [{deviceId:$id,publicKey:$public,encryptionPublicKey:$encryptionPublic,sshUser:$sshUser,sshPublicKey:$sshPublic,label:$display,role:$role,status:"active",vlessUuid:$uuid,subId:$sub,createdAt:$now,updatedAt:$now}]' \
      --arg id "$device_id" --arg public "$public" --arg encryptionPublic "$encryption_public" --arg sshUser "$ssh_user" --arg sshPublic "$ssh_public" --arg display "$label" --arg role "$role" --arg uuid "$uuid" --arg sub "$sub_id" --arg now "$now"
  fi
  commit_transaction
}

status_registry() {
  init_registry
  echo '__TNA_DEVICE_STATUS_V1_BEGIN__'
  printf 'NODE_ID=%s\n' "$(jq -r '.nodeId' "$REGISTRY")"
  printf 'CONTROLLER_ACTIVE_COUNT=%s\n' "$(jq '[.devices[] | select(.role=="controller" and .status=="active")] | length' "$REGISTRY")"
  printf 'DEVICE_ACTIVE_COUNT=%s\n' "$(jq '[.devices[] | select(.status=="active")] | length' "$REGISTRY")"
  jq -r '.devices[] | [.deviceId,.role,.status,(.label|gsub("[\\t\\r\\n]";"_")),.createdAt] | @tsv' "$REGISTRY" | while IFS=$'\t' read -r id role status label created; do
    printf 'DEVICE\t%s\t%s\t%s\t%s\t%s\n' "$id" "$role" "$status" "$label" "$created"
  done
  echo 'PER_DEVICE_VLESS=SUPPORTED'
  echo 'CDN_MTLS_DEVICE=EXPERIMENTAL_BLOCKED'
  echo 'WIREGUARD_DEVICE_LOCK=EXPERIMENTAL_BLOCKED'
  echo '__TNA_DEVICE_STATUS_V1_END__'
}

bootstrap_controller() {
  init_registry
  [ "$(jq '[.devices[] | select(.role=="controller" and .status=="active")] | length' "$REGISTRY")" -eq 0 ] || die CONTROLLER_ALREADY_EXISTS 69
  INPUT_NONCE=''
  read_enrollment_input
  [ "$INPUT_ROLE" = controller ] || die FIRST_DEVICE_MUST_BE_CONTROLLER 69
  register_device "$INPUT_PUBLIC" "$INPUT_LABEL" "$INPUT_ROLE" "$DEVICE_ID" "$INPUT_ENCRYPTION_PUBLIC" "$INPUT_SSH_USER" "$INPUT_SSH_PUBLIC"
  printf '__TNA_DEVICE_BOOTSTRAP_V1_BEGIN__\nDEVICE_ID=%s\nROLE=controller\nSTATUS=active\n__TNA_DEVICE_BOOTSTRAP_V1_END__\n' "$DEVICE_ID"
}

create_invite() {
  local controller_id="${1:-}" ssh_user="${2:-}" nonce hash now
  init_registry
  jq -e --arg id "$controller_id" 'any(.devices[]?; .deviceId==$id and .role=="controller" and .status=="active")' "$REGISTRY" >/dev/null || die ACTIVE_CONTROLLER_REQUIRED 70
  validate_ssh_user "$ssh_user" || die SSH_LOGIN_USER_INVALID 70
  nonce="$(openssl rand -hex 32)"
  hash="$(printf '%s' "$nonce" | sha256sum | awk '{print $1}')"
  now="$(date +%s)"
  write_registry '.invites |= map(select((.used // false)==true or ((.reservedDeviceId // "") != ""))) | .invites += [{nonceSha256:$hash,createdBy:$controller,sshUser:$sshUser,createdAtEpoch:$now,used:false,consumePolicy:"successful-bind"}]' \
    --arg hash "$hash" --arg controller "$controller_id" --arg sshUser "$ssh_user" --argjson now "$now"
  printf '__TNA_DEVICE_INVITE_V2_BEGIN__\nENROLLMENT_NONCE=%s\nEXPIRES_ON_SUCCESSFUL_BIND=1\nNODE_ID=%s\n__TNA_DEVICE_INVITE_V2_END__\n' \
    "$nonce" "$(jq -r '.nodeId' "$REGISTRY")"
}

enroll_device() {
  local hash now index existing
  init_registry
  read_enrollment_input
  [[ "${INPUT_NONCE:-}" =~ ^[0-9a-f]{64}$ ]] || die NONCE_INVALID 71
	verify_enrollment_signature "$(jq -r '.nodeId' "$REGISTRY")" "$INPUT_NONCE" "$DEVICE_ID" "$INPUT_PUBLIC" "$INPUT_LABEL" "$INPUT_ROLE" "$INPUT_ENCRYPTION_PUBLIC" "$INPUT_SSH_USER" "$INPUT_SSH_PUBLIC" "${INPUT_SIGNATURE:-}"
  hash="$(printf '%s' "$INPUT_NONCE" | sha256sum | awk '{print $1}')"
  now="$(date +%s)"
  index="$(jq -r --arg hash "$hash" --arg sshUser "$INPUT_SSH_USER" '.invites | to_entries[]? | select(.value.nonceSha256==$hash and .value.used==false and .value.consumePolicy=="successful-bind" and .value.sshUser==$sshUser) | .key' "$REGISTRY" | sed -n '1p')"
  [[ "$index" =~ ^[0-9]+$ ]] || die NONCE_INVALID_OR_USED 71
  existing="$(jq -c --arg id "$DEVICE_ID" --arg hash "$hash" '.devices[]? | select(.deviceId==$id and .status=="pending-verification" and .inviteNonceSha256==$hash)' "$REGISTRY")"
  if [ -n "$existing" ]; then
    jq -e --arg public "$INPUT_PUBLIC" --arg encryptionPublic "$INPUT_ENCRYPTION_PUBLIC" --arg sshUser "$INPUT_SSH_USER" --arg ssh "$INPUT_SSH_PUBLIC" --arg role "$INPUT_ROLE" '.publicKey==$public and .encryptionPublicKey==$encryptionPublic and .sshUser==$sshUser and .sshPublicKey==$ssh and .role==$role' <<< "$existing" >/dev/null || die PENDING_RESPONSE_MISMATCH 71
    printf '__TNA_DEVICE_ENROLL_V2_BEGIN__\nDEVICE_ID=%s\nROLE=%s\nSTATUS=pending-verification\nNONCE_CONSUMED=0\nIDEMPOTENT_REPLAY=1\n__TNA_DEVICE_ENROLL_V2_END__\n' "$DEVICE_ID" "$INPUT_ROLE"
    return
  fi
  [ "$(jq -r --argjson index "$index" '.invites[$index].reservedDeviceId // ""' "$REGISTRY")" = "" ] || die INVITE_ALREADY_RESERVED 71
  register_device "$INPUT_PUBLIC" "$INPUT_LABEL" "$INPUT_ROLE" "$DEVICE_ID" "$INPUT_ENCRYPTION_PUBLIC" "$INPUT_SSH_USER" "$INPUT_SSH_PUBLIC" "$index"
  printf '__TNA_DEVICE_ENROLL_V2_BEGIN__\nDEVICE_ID=%s\nROLE=%s\nSTATUS=pending-verification\nNONCE_CONSUMED=0\n__TNA_DEVICE_ENROLL_V2_END__\n' "$DEVICE_ID" "$INPUT_ROLE"
}

claim_forced() {
  local device_id="${1:-}" nonce_hash="${2:-}" device invite_index role public ssh_user now
  [[ "$device_id" =~ ^(tna|pna)-device-[a-z2-7]{26}$ ]] || die DEVICE_ID_INVALID 75
  [[ "$nonce_hash" =~ ^[0-9a-f]{64}$ ]] || die INVITE_HASH_INVALID 75
  device="$(jq -c --arg id "$device_id" --arg hash "$nonce_hash" '.devices[]? | select(.deviceId==$id and .status=="pending-verification" and .inviteNonceSha256==$hash)' "$REGISTRY")"
  [ -n "$device" ] || die DEVICE_BIND_NOT_PENDING 75
  invite_index="$(jq -r --arg hash "$nonce_hash" --arg id "$device_id" '.invites | to_entries[]? | select(.value.nonceSha256==$hash and .value.used==false and .value.reservedDeviceId==$id) | .key' "$REGISTRY" | sed -n '1p')"
  [[ "$invite_index" =~ ^[0-9]+$ ]] || die INVITE_NOT_RESERVED 75
  role="$(jq -r '.role' <<< "$device")"
  public="$(jq -r '.sshPublicKey' <<< "$device")"
  ssh_user="$(jq -r '.sshUser' <<< "$device")"
	if [ "$role" = controller ] && [ -d "$DRIVE_ESCROW_DIR" ]; then
		local encryption_public escrow
		encryption_public="$(jq -r '.encryptionPublicKey' <<< "$device")"
		for escrow in "$DRIVE_ESCROW_DIR"/tna-account-*.json; do
			[ -e "$escrow" ] || continue
			jq -e --arg id "$device_id" --arg public "$encryption_public" \
				'any(.envelopes[]?; .deviceId==$id and .encryptionPublicKey==$public)' "$escrow" >/dev/null || \
				die CONTROLLER_ESCROW_NOT_READY 77
		done
	fi
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  begin_transaction claim "$device_id"
  for object in "$(get_reality)" "$(get_xhttp)"; do
    [ -n "$object" ] || continue
    if ! jq -e --arg marker "tna-device:${device_id}" 'any(.settings.clients[]?; (.comment // "")==$marker)' <<< "$object" >/dev/null; then continue; fi
    id="$(jq -r '.id' <<< "$object")"
    printf '%s\n' "$object" > "$TX_DIR/${id}.json"
    payload="$(payload_set_client_enabled "$object" "$device_id" true)"
    update_inbound "$id" "$payload" || die XUI_CLIENT_UPDATE_FAILED 66
    now_object="$(get_by_id "$id")"
    jq -e --arg marker "tna-device:${device_id}" 'any(.settings.clients[]?; (.comment // "")==$marker and .enable==true)' <<< "$now_object" >/dev/null || die XUI_CLIENT_READBACK_FAILED 66
  done
  install_device_ssh_key "$device_id" "$public" "$role" "$ssh_user" active
  write_registry '(.devices[] | select(.deviceId==$id) | .status)="active" | (.devices[] | select(.deviceId==$id) | .updatedAt)=$now | del(.devices[] | select(.deviceId==$id) | .inviteNonceSha256) | (.invites[$index].used)=true | (.invites[$index].usedAt)=$now' \
    --arg id "$device_id" --arg now "$now" --argjson index "$invite_index"
  commit_transaction
  printf '__TNA_DEVICE_BIND_V2_BEGIN__\nDEVICE_ID=%s\nSTATUS=active\nNONCE_CONSUMED=1\n' "$device_id"
  device_handoff "$device_id"
  echo '__TNA_DEVICE_BIND_V2_END__'
}

require_active_controller() {
  local id="$1"
  jq -e --arg id "$id" 'any(.devices[]?; .deviceId==$id and .role=="controller" and .status=="active")' "$REGISTRY" >/dev/null || die ACTIVE_CONTROLLER_REQUIRED 70
}

traffic_forced() {
  local id="$1" original="${SSH_ORIGINAL_COMMAND:-}" username line account_id space_id role status quota node_id drive_port
  init_registry
  jq -e --arg id "$id" 'any(.devices[]?; .deviceId==$id and .role=="traffic-only" and .status=="active")' "$REGISTRY" >/dev/null || die ACTIVE_TRAFFIC_DEVICE_REQUIRED 78
  node_id="$(jq -r '.nodeId' "$REGISTRY")"
  drive_port="$(sed -n 's/^COPYPARTY_LOOPBACK_PORT=//p' "$STATE_DIR/private-drive.env" 2>/dev/null | sed -n '1p')"
  [[ "$drive_port" =~ ^39[0-9]{3}$ ]] || die DRIVE_LOOPBACK_PORT_MISSING 78
  case "$original" in
    drive-meta)
      printf '__TNA_TRAFFIC_META_V1_BEGIN__\nNODE_ID=%s\nDEVICE_ID=%s\nDEVICE_ROLE=traffic-only\nDRIVE_LOOPBACK_PORT=%s\nTOOLKIT_BUILD_ID=' "$node_id" "$id" "$drive_port"
      tr -d '\r\n' < "$ROOT/TOOLKIT_BUILD_ID"
      printf '\nTOOLKIT_BUILD_REVISION='
      tr -d '\r\n' < "$ROOT/TOOLKIT_BUILD_REVISION"
      printf '\n__TNA_TRAFFIC_META_V1_END__\n'
      ;;
    drive-change-context\ *)
      username="${original#drive-change-context }"
      tna_drive_valid_ordinary_username "$username" || die ORDINARY_USERNAME_INVALID 78
      line="$(awk -F '\t' -v user="$username" '$5==user {print; exit}' "$DRIVE_REGISTRY_FILE")"
      [ -n "$line" ] || die ACCOUNT_NOT_FOUND 78
      IFS=$'\t' read -r account_id space_id role status _ _ quota _ <<<"$line"
      [ "$role" = ordinary ] && [ "$status" = active ] || die ACCOUNT_NOT_ACTIVE 78
      printf '__TNA_TRAFFIC_CHANGE_CONTEXT_V1_BEGIN__\nNODE_ID=%s\nACCOUNT_ID=%s\nSPACE_ID=%s\nUSERNAME=%s\nQUOTA_GIB=%s\n' "$node_id" "$account_id" "$space_id" "$username" "$quota"
      jq -r '.devices[] | select(.role=="controller" and .status=="active") | [.deviceId,.encryptionPublicKey] | @tsv' "$REGISTRY" |
        while IFS=$'\t' read -r controller public; do printf 'CONTROLLER\t%s\t%s\n' "$controller" "$public"; done
      printf '__TNA_TRAFFIC_CHANGE_CONTEXT_V1_END__\n'
      ;;
    drive-change-password\ *)
      username="${original#drive-change-password }"
      tna_drive_valid_ordinary_username "$username" || die ORDINARY_USERNAME_INVALID 78
      exec bash "$ROOT/linux/30-copyparty-account.sh" change-password "$username"
      ;;
    *) die TRAFFIC_COMMAND_DENIED 126 ;;
  esac
}

refresh_device_ssh_keys() {
  local controller="$1" id public role ssh_user refreshed=0
  init_registry
  require_active_controller "$controller"
  begin_transaction refresh-device-ssh-keys "$controller"
  while IFS=$'\t' read -r id public role ssh_user; do
    [ -n "$id" ] || continue
    install_device_ssh_key "$id" "$public" "$role" "$ssh_user" active
    refreshed=$((refreshed + 1))
  done < <(jq -r '.devices[] | select(.status=="active") | [.deviceId,.sshPublicKey,.role,.sshUser] | @tsv' "$REGISTRY")
  commit_transaction
  printf 'TNA_DEVICE_SSH_KEYS_REFRESHED=%s\n' "$refreshed"
}

controller_encryption_keys() {
  local controller="$1" include_pending="${2:-active-only}" filter
  init_registry
  require_active_controller "$controller"
	case "$include_pending" in
		active-only) filter='select(.role=="controller" and .status=="active")' ;;
		include-pending) filter='select(.role=="controller" and (.status=="active" or .status=="pending-verification"))' ;;
		*) die USAGE 2 ;;
	esac
  echo '__TNA_CONTROLLER_ENCRYPTION_KEYS_V1_BEGIN__'
	jq -r ".devices[] | ${filter} | [.deviceId,.encryptionPublicKey] | @tsv" "$REGISTRY" |
    while IFS=$'\t' read -r id public; do
      [[ "$id" =~ ^(tna|pna)-device-[a-z2-7]{26}$ ]] && [[ "$public" =~ ^tna-x25519:[A-Za-z0-9_-]{43}$ ]] || die CONTROLLER_ENCRYPTION_KEY_MISSING 76
      printf 'CONTROLLER\t%s\t%s\n' "$id" "$public"
    done
  echo '__TNA_CONTROLLER_ENCRYPTION_KEYS_V1_END__'
}

refresh_controller_encryption_key() {
	local controller="$1" encryption_public signature current signing_public
	init_registry
	require_active_controller "$controller"
	IFS= read -r encryption_public || true
	IFS= read -r signature || true
	[[ "$encryption_public" =~ ^tna-x25519:[A-Za-z0-9_-]{43}$ ]] || die ENCRYPTION_PUBLIC_KEY_INVALID 78
	current="$(jq -r --arg id "$controller" '.devices[] | select(.deviceId==$id) | .encryptionPublicKey // empty' "$REGISTRY")"
	if [ -n "$current" ]; then
		[ "$current" = "$encryption_public" ] || die CONTROLLER_ENCRYPTION_KEY_ROTATION_REQUIRES_ESCROW_MIGRATION 78
		printf 'CONTROLLER_ENCRYPTION_KEY_READY=1\nIDEMPOTENT=1\n'
		return
	fi
	signing_public="$(jq -r --arg id "$controller" '.devices[] | select(.deviceId==$id) | .publicKey' "$REGISTRY")"
	verify_controller_encryption_signature "$(jq -r '.nodeId' "$REGISTRY")" "$controller" "$signing_public" "$encryption_public" "$signature"
	write_registry '(.devices[] | select(.deviceId==$id) | .encryptionPublicKey)=$public | (.devices[] | select(.deviceId==$id) | .updatedAt)=$now' \
		--arg id "$controller" --arg public "$encryption_public" --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
	printf 'CONTROLLER_ENCRYPTION_KEY_READY=1\nIDEMPOTENT=0\n'
}

change_device_state() {
  local action="$1" controller="$2" target="$3" role target_status active_controllers
  init_registry
  require_active_controller "$controller"
  jq -e --arg id "$target" 'any(.devices[]?; .deviceId==$id and .status!="revoked")' "$REGISTRY" >/dev/null || die TARGET_DEVICE_NOT_ACTIVE 72
  role="$(jq -r --arg id "$target" '.devices[] | select(.deviceId==$id) | .role' "$REGISTRY")"
  target_status="$(jq -r --arg id "$target" '.devices[] | select(.deviceId==$id) | .status' "$REGISTRY")"
  active_controllers="$(jq '[.devices[] | select(.role=="controller" and .status=="active")] | length' "$REGISTRY")"
  if [ "$role" = controller ] && [ "$active_controllers" -le 1 ] && [ "$action" != resume ]; then die LAST_CONTROLLER_PROTECTED 73; fi
  case "$action" in
    pause) [ "$target_status" != pending-verification ] || die PENDING_DEVICE_CAN_ONLY_BE_REVOKED 72; set_device_enabled "$target" false ;;
    resume) [ "$target_status" != pending-verification ] || die PENDING_DEVICE_CAN_ONLY_BE_REVOKED 72; set_device_enabled "$target" true ;;
    revoke) delete_device_clients "$target" ;;
    *) die INVALID_STATE_ACTION 2 ;;
  esac
  printf '__TNA_DEVICE_STATE_V1_BEGIN__\nDEVICE_ID=%s\nSTATUS=%s\n__TNA_DEVICE_STATE_V1_END__\n' "$target" "$([ "$action" = revoke ] && echo revoked || { [ "$action" = pause ] && echo paused || echo active; })"
}

device_handoff() {
  local id="$1" device uuid gray_domain orange_domain mode public reality reality_key short_id direct_link='' xhttp path xhttp_link='' drive_port
  init_registry
  device="$(jq -c --arg id "$id" '.devices[]? | select(.deviceId==$id and .status=="active")' "$REGISTRY")"
  [ -n "$device" ] || die ACTIVE_DEVICE_NOT_FOUND 74
  uuid="$(jq -r '.vlessUuid' <<< "$device")"
  mode="$(sed -n 's/^TOPOLOGY_MODE=//p' /root/.config/text-node-assistant/topology.env 2>/dev/null | sed -n '1p')"
  gray_domain="$(sed -n 's/^GRAY_DOMAIN=//p' /root/.config/text-node-assistant/topology.env 2>/dev/null | sed -n '1p')"
  orange_domain="$(sed -n 's/^ORANGE_DOMAIN=//p' /root/.config/text-node-assistant/topology.env 2>/dev/null | sed -n '1p')"
  if [ -z "$mode" ]; then
    mode=gray
    gray_domain="$(sed -n 's/^COVER_DOMAIN=//p' /etc/text-node-assistant/public.env 2>/dev/null | sed -n '1p')"
  fi
  [[ "$mode" =~ ^(gray|orange|dual)$ ]] || die TOPOLOGY_MODE_INVALID 74
  public="$(sed -n 's/^PUBLIC_IP=//p' /etc/text-node-assistant/public.env 2>/dev/null | sed -n '1p')"
  if [ "$mode" = gray ] || [ "$mode" = dual ]; then
    reality="$(get_reality)"
    [ -n "$reality" ] || die HANDOFF_CONTEXT_MISSING 74
    [ -n "$gray_domain" ] && [ -n "$public" ] || die DIRECT_HANDOFF_CONTEXT_MISSING 74
    reality_key="$(jq -r '.streamSettings.realitySettings.settings.publicKey // .streamSettings.realitySettings.settings.password // empty' <<< "$reality")"
    short_id="$(jq -r '.streamSettings.realitySettings.shortIds[0] // empty' <<< "$reality")"
    direct_link="vless://${uuid}@${public}:443?type=tcp&security=reality&pbk=$(jq -rn --arg v "$reality_key" '$v|@uri')&fp=chrome&sni=$(jq -rn --arg v "$gray_domain" '$v|@uri')&sid=$(jq -rn --arg v "$short_id" '$v|@uri')&spx=%2F&flow=xtls-rprx-vision#$(jq -rn --arg v "$id" '$v|@uri')"
  fi
  xhttp="$(get_xhttp)"
  if { [ "$mode" = orange ] || [ "$mode" = dual ]; } && [ -n "$orange_domain" ] && [ -n "$xhttp" ] && jq -e --arg uuid "$uuid" 'any(.settings.clients[]?; .id==$uuid and .enable==true)' <<< "$xhttp" >/dev/null; then
    path="$(jq -r '.streamSettings.xhttpSettings.path // empty' <<< "$xhttp")"
    xhttp_link="vless://${uuid}@${orange_domain}:8443?encryption=none&security=tls&sni=$(jq -rn --arg v "$orange_domain" '$v|@uri')&fp=chrome&type=xhttp&host=$(jq -rn --arg v "$orange_domain" '$v|@uri')&path=$(jq -rn --arg v "$path" '$v|@uri')&mode=packet-up#$(jq -rn --arg v "${id}-cdn" '$v|@uri')"
  fi
  [ -n "$direct_link" ] || [ -n "$xhttp_link" ] || die NO_ACTIVE_TOPOLOGY_HANDOFF 74
  drive_port="$(sed -n 's/^COPYPARTY_LOOPBACK_PORT=//p' "$STATE_DIR/private-drive.env" 2>/dev/null | sed -n '1p')"
  [[ "$drive_port" =~ ^39[0-9]{3}$ ]] || die DRIVE_LOOPBACK_PORT_MISSING 74
  echo '__TNA_DEVICE_HANDOFF_V1_BEGIN__'
  printf 'DEVICE_ID=%s\nDEVICE_ROLE=%s\nDRIVE_LOOPBACK_PORT=%s\nTOPOLOGY_MODE=%s\n' "$id" "$(jq -r '.role' <<< "$device")" "$drive_port" "$mode"
  [ -z "$direct_link" ] || printf 'DIRECT_REALITY_LINK=%s\n' "$direct_link"
  [ -z "$xhttp_link" ] || printf 'CDN_XHTTP_LINK=%s\n' "$xhttp_link"
  echo '__TNA_DEVICE_HANDOFF_V1_END__'
}

init_registry
case "$COMMAND" in
  status) [ "$#" -eq 0 ] || die USAGE 2; status_registry ;;
  bootstrap-controller) [ "$#" -eq 0 ] || die USAGE 2; bootstrap_controller ;;
  create-invite) [ "$#" -eq 2 ] || die USAGE 2; create_invite "$1" "$2" ;;
  enroll) [ "$#" -eq 0 ] || die USAGE 2; enroll_device ;;
  claim-forced) [ "$#" -eq 2 ] || die USAGE 2; claim_forced "$1" "$2" ;;
  controller-encryption-keys) { [ "$#" -eq 1 ] || [ "$#" -eq 2 ]; } || die USAGE 2; controller_encryption_keys "$@" ;;
	refresh-controller-encryption-key) [ "$#" -eq 1 ] || die USAGE 2; refresh_controller_encryption_key "$1" ;;
  traffic-forced) [ "$#" -eq 1 ] || die USAGE 2; traffic_forced "$1" ;;
  refresh-device-ssh-keys) [ "$#" -eq 1 ] || die USAGE 2; refresh_device_ssh_keys "$1" ;;
  pause|resume|revoke) [ "$#" -eq 2 ] || die USAGE 2; change_device_state "$COMMAND" "$1" "$2" ;;
  handoff) [ "$#" -eq 1 ] || die USAGE 2; device_handoff "$1" ;;
  *) die USAGE 2 ;;
esac
