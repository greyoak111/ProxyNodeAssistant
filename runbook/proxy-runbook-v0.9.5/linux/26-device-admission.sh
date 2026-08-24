#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/linux/lib-xui-api.sh"

COMMAND="${1:-status}"
shift || true
STATE_DIR="/etc/proxy-runbook"
REGISTRY="$STATE_DIR/device-registry.json"
LOCK_FILE="/run/lock/proxy-node-assistant-device-admission.lock"
TX_DIR=''
TX_ACTIVE=0
TX_ACTION=''
TX_DEVICE_ID=''

die() {
  printf 'PNA_DEVICE_ERROR=%s\n' "$1" >&2
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
  [[ "$id" =~ ^pna-node-[0-9a-f]{32}$ ]] || die NODE_IDENTITY_NOT_INITIALIZED 62
  printf '%s' "$id"
}

init_registry() {
  if [ -s "$REGISTRY" ]; then
    jq -e '.version == 1 and (.nodeId | type == "string") and (.devices | type == "array") and (.invites | type == "array")' "$REGISTRY" >/dev/null || die REGISTRY_INVALID 62
    [ "$(jq -r '.nodeId' "$REGISTRY")" = "$(node_id)" ] || die REGISTRY_NODE_ID_MISMATCH 62
    return
  fi
  local tmp
  tmp="$(mktemp "$STATE_DIR/.device-registry.XXXXXX")"
  jq -nc --arg node "$(node_id)" '{version:1,nodeId:$node,devices:[],invites:[]}' > "$tmp"
  chmod 600 "$tmp"
  mv -f -- "$tmp" "$REGISTRY"
}

write_registry() {
  local filter="$1"; shift
  local tmp
  tmp="$(mktemp "$STATE_DIR/.device-registry.XXXXXX")"
  jq "$@" "$filter" "$REGISTRY" > "$tmp" || { rm -f "$tmp"; die REGISTRY_UPDATE_FAILED 63; }
  jq -e '.version == 1 and (.devices | type == "array") and (.invites | type == "array")' "$tmp" >/dev/null || { rm -f "$tmp"; die REGISTRY_UPDATE_INVALID 63; }
  chmod 600 "$tmp"
  mv -f -- "$tmp" "$REGISTRY"
}

validate_label() {
  local pattern='^[A-Za-z0-9._ -]+$'
  [ "${#1}" -ge 1 ] && [ "${#1}" -le 64 ] && [[ "$1" =~ $pattern ]]
}

validate_role() { [ "$1" = controller ] || [ "$1" = traffic-only ]; }

device_id_from_public() {
  python3 - "$1" <<'PY'
import base64,hashlib,re,sys
value=sys.argv[1]
if not re.fullmatch(r'pna-ed25519:[A-Za-z0-9_-]{43}', value):
    raise SystemExit(1)
raw=base64.urlsafe_b64decode(value.split(':',1)[1]+'=')
if len(raw) != 32:
    raise SystemExit(1)
print('pna-device-'+base64.b32encode(hashlib.sha256(raw).digest()[:16]).decode().rstrip('=').lower())
PY
}

verify_enrollment_signature() {
  local node="$1" nonce="$2" device_id="$3" public="$4" label="$5" role="$6" signature="$7"
  local verify_dir public_der
  [[ "$signature" =~ ^[A-Za-z0-9_-]{86}$ ]] || die SIGNATURE_INVALID 71
  verify_dir="$(mktemp -d /tmp/pna-device-verify.XXXXXX)"
  trap 'rm -rf -- "$verify_dir"' RETURN
  python3 - "$public" "$signature" "$verify_dir/public.pem" "$verify_dir/signature.bin" <<'PY'
import base64,re,sys
public,signature,pem_path,sig_path=sys.argv[1:]
if not re.fullmatch(r'pna-ed25519:[A-Za-z0-9_-]{43}', public):
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
  printf 'PNA-DEVICE-ENROLL-V1\nNODE_ID=%s\nNONCE=%s\nDEVICE_ID=%s\nPUBLIC_KEY=%s\nLABEL=%s\nROLE=%s\n' \
    "$node" "$nonce" "$device_id" "$public" "$label" "$role" > "$verify_dir/message.bin"
  openssl pkeyutl -verify -pubin -inkey "$verify_dir/public.pem" -rawin -in "$verify_dir/message.bin" -sigfile "$verify_dir/signature.bin" >/dev/null 2>&1 || die SIGNATURE_INVALID 71
  rm -rf -- "$verify_dir"
  trap - RETURN
}

read_enrollment_input() {
  IFS= read -r INPUT_NONCE || true
  IFS= read -r INPUT_PUBLIC || true
  IFS= read -r INPUT_LABEL || true
  IFS= read -r INPUT_ROLE || true
	IFS= read -r INPUT_SIGNATURE || true
  [ -n "${INPUT_PUBLIC:-}" ] || die PUBLIC_KEY_MISSING 64
  DEVICE_ID="$(device_id_from_public "$INPUT_PUBLIC")" || die PUBLIC_KEY_INVALID 64
  validate_label "${INPUT_LABEL:-}" || die LABEL_INVALID 64
  validate_role "${INPUT_ROLE:-}" || die ROLE_INVALID 64
}

list_inbounds() { xui_api_get '/panel/api/inbounds/list'; }
get_reality() { list_inbounds | jq -c '.obj[]? | select(.port==443 and .protocol=="vless" and .streamSettings.security=="reality")' | sed -n '1p'; }
get_xhttp() { list_inbounds | jq -c '.obj[]? | select(.remark=="pna-cdn-xhttp" and .protocol=="vless" and .streamSettings.network=="xhttp")' | sed -n '1p'; }
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
  jq -c --arg marker "pna-device:${device_id}" --argjson enabled "$enabled" '
    {enable,remark,listen,port,protocol,expiryTime,total,settings,streamSettings,sniffing,
     tag,allocate,subSortIndex,trafficReset,trafficResetDay,shareAddrStrategy,shareAddr}
    | .settings.clients |= map(if (.comment // "") == $marker then .enable=$enabled else . end)
  ' <<< "$object"
}

payload_delete_client() {
  local object="$1" device_id="$2"
  jq -c --arg marker "pna-device:${device_id}" '
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
  TX_DIR="$(mktemp -d /tmp/pna-device-tx.XXXXXX)"
  cp -a "$REGISTRY" "$TX_DIR/registry.json"
  TX_ACTIVE=1
}

commit_transaction() {
  TX_ACTIVE=0
  TX_ACTION=''
  TX_DEVICE_ID=''
  case "$TX_DIR" in /tmp/pna-device-tx.*) rm -rf -- "$TX_DIR";; *) die TRANSACTION_DIRECTORY_INVALID 63;; esac
  TX_DIR=''
}

transaction_exit() {
  local rc="$1" rollback_failed=0 tmp
  trap - EXIT
  if [ "$TX_ACTIVE" -eq 1 ]; then
    rollback_inbounds || rollback_failed=1
    cp -a "$TX_DIR/registry.json" "$REGISTRY" 2>/dev/null || rollback_failed=1
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
      echo 'PNA_DEVICE_REVOCATION_PARTIAL=1' >&2
    elif [ "$rollback_failed" -eq 1 ]; then
      echo 'PNA_DEVICE_TRANSACTION_PARTIAL=1' >&2
    else
      echo 'PNA_DEVICE_TRANSACTION_ROLLED_BACK=1' >&2
    fi
    case "$TX_DIR" in /tmp/pna-device-tx.*) rm -rf -- "$TX_DIR";; esac
  fi
  exit "$rc"
}

trap 'transaction_exit "$?"' EXIT

apply_new_clients() {
  local device_id="$1" uuid="$2" sub_id="$3" reality xhttp object id client payload now
  reality="$(get_reality)"
  [ -n "$reality" ] || die REALITY_443_MISSING 65
  xhttp="$(get_xhttp)"
  for object in "$reality" "$xhttp"; do
    [ -n "$object" ] || continue
    id="$(jq -r '.id' <<< "$object")"
    cp -a /dev/null "$TX_DIR/${id}.json"
    printf '%s\n' "$object" > "$TX_DIR/${id}.json"
    jq -e --arg marker "pna-device:${device_id}" 'all(.settings.clients[]?; (.comment // "") != $marker)' <<< "$object" >/dev/null || die DEVICE_CLIENT_ALREADY_EXISTS 65
    if [ "$(jq -r '.streamSettings.security // ""' <<< "$object")" = reality ]; then
      client="$(jq -nc --arg uuid "$uuid" --arg sub "$sub_id" --arg marker "pna-device:${device_id}" '{id:$uuid,email:$marker,flow:"xtls-rprx-vision",limitIp:0,totalGB:0,expiryTime:0,enable:true,tgId:0,subId:$sub,comment:$marker}')"
    else
      client="$(jq -nc --arg uuid "$uuid" --arg sub "$sub_id" --arg marker "pna-device:${device_id}" '{id:$uuid,email:$marker,flow:"",limitIp:0,totalGB:0,expiryTime:0,enable:true,tgId:0,subId:$sub,comment:$marker}')"
    fi
    payload="$(payload_with_client "$object" "$client")"
    update_inbound "$id" "$payload" || die XUI_CLIENT_UPDATE_FAILED 66
    now="$(get_by_id "$id")"
    jq -e --arg uuid "$uuid" --arg marker "pna-device:${device_id}" 'any(.settings.clients[]?; .id==$uuid and (.comment // "")==$marker and .enable==true)' <<< "$now" >/dev/null || die XUI_CLIENT_READBACK_FAILED 66
  done
}

set_device_enabled() {
  local device_id="$1" enabled="$2" object id payload now found=0
  begin_transaction "$([ "$enabled" = true ] && echo resume || echo pause)" "$device_id"
  for object in "$(get_reality)" "$(get_xhttp)"; do
    [ -n "$object" ] || continue
    if ! jq -e --arg marker "pna-device:${device_id}" 'any(.settings.clients[]?; (.comment // "")==$marker)' <<< "$object" >/dev/null; then continue; fi
    found=1
    id="$(jq -r '.id' <<< "$object")"
    printf '%s\n' "$object" > "$TX_DIR/${id}.json"
    payload="$(payload_set_client_enabled "$object" "$device_id" "$enabled")"
    update_inbound "$id" "$payload" || die XUI_CLIENT_UPDATE_FAILED 66
    now="$(get_by_id "$id")"
    jq -e --arg marker "pna-device:${device_id}" --argjson enabled "$enabled" 'any(.settings.clients[]?; (.comment // "")==$marker and .enable==$enabled)' <<< "$now" >/dev/null || die XUI_CLIENT_READBACK_FAILED 66
  done
  [ "$found" -eq 1 ] || die DEVICE_CLIENT_MISSING 66
  write_registry '(.devices[] | select(.deviceId==$id) | .status)=$status | (.devices[] | select(.deviceId==$id) | .updatedAt)=$now' \
    --arg id "$device_id" --arg status "$([ "$enabled" = true ] && echo active || echo paused)" --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  commit_transaction
}

delete_device_clients() {
  local device_id="$1" object id payload now
  begin_transaction revoke "$device_id"
  for object in "$(get_reality)" "$(get_xhttp)"; do
    [ -n "$object" ] || continue
    if ! jq -e --arg marker "pna-device:${device_id}" 'any(.settings.clients[]?; (.comment // "")==$marker)' <<< "$object" >/dev/null; then continue; fi
    id="$(jq -r '.id' <<< "$object")"
    printf '%s\n' "$object" > "$TX_DIR/${id}.json"
    payload="$(payload_delete_client "$object" "$device_id")"
    update_inbound "$id" "$payload" || die XUI_CLIENT_DELETE_FAILED 67
    now="$(get_by_id "$id")"
    jq -e --arg marker "pna-device:${device_id}" 'all(.settings.clients[]?; (.comment // "") != $marker)' <<< "$now" >/dev/null || die XUI_CLIENT_DELETE_READBACK_FAILED 67
  done
  write_registry '(.devices[] | select(.deviceId==$id) | .status)="revoked" | (.devices[] | select(.deviceId==$id) | .updatedAt)=$now' \
    --arg id "$device_id" --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  commit_transaction
}

register_device() {
  local public="$1" label="$2" role="$3" device_id="$4" invite_index="${5:-}" uuid sub_id now
  jq -e --arg id "$device_id" 'all(.devices[]?; .deviceId != $id)' "$REGISTRY" >/dev/null || die DEVICE_ALREADY_REGISTERED 68
  uuid="$(xui_new_uuid)"
  sub_id="$(openssl rand -hex 16)"
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  begin_transaction enroll "$device_id"
  apply_new_clients "$device_id" "$uuid" "$sub_id"
  if [ -n "$invite_index" ]; then
    write_registry '.devices += [{deviceId:$id,publicKey:$public,label:$display,role:$role,status:"active",vlessUuid:$uuid,subId:$sub,createdAt:$now,updatedAt:$now}] | (.invites[$index].used)=true | (.invites[$index].usedAt)=$now' \
      --arg id "$device_id" --arg public "$public" --arg display "$label" --arg role "$role" --arg uuid "$uuid" --arg sub "$sub_id" --arg now "$now" --argjson index "$invite_index"
  else
    write_registry '.devices += [{deviceId:$id,publicKey:$public,label:$display,role:$role,status:"active",vlessUuid:$uuid,subId:$sub,createdAt:$now,updatedAt:$now}]' \
      --arg id "$device_id" --arg public "$public" --arg display "$label" --arg role "$role" --arg uuid "$uuid" --arg sub "$sub_id" --arg now "$now"
  fi
  commit_transaction
}

status_registry() {
  init_registry
  echo '__PNA_DEVICE_STATUS_V1_BEGIN__'
  printf 'NODE_ID=%s\n' "$(jq -r '.nodeId' "$REGISTRY")"
  printf 'CONTROLLER_ACTIVE_COUNT=%s\n' "$(jq '[.devices[] | select(.role=="controller" and .status=="active")] | length' "$REGISTRY")"
  printf 'DEVICE_ACTIVE_COUNT=%s\n' "$(jq '[.devices[] | select(.status=="active")] | length' "$REGISTRY")"
  jq -r '.devices[] | [.deviceId,.role,.status,(.label|gsub("[\\t\\r\\n]";"_")),.createdAt] | @tsv' "$REGISTRY" | while IFS=$'\t' read -r id role status label created; do
    printf 'DEVICE\t%s\t%s\t%s\t%s\t%s\n' "$id" "$role" "$status" "$label" "$created"
  done
  echo 'PER_DEVICE_VLESS=SUPPORTED'
  echo 'CDN_MTLS_DEVICE=EXPERIMENTAL_BLOCKED'
  echo 'WIREGUARD_DEVICE_LOCK=EXPERIMENTAL_BLOCKED'
  echo '__PNA_DEVICE_STATUS_V1_END__'
}

bootstrap_controller() {
  init_registry
  [ "$(jq '[.devices[] | select(.role=="controller" and .status=="active")] | length' "$REGISTRY")" -eq 0 ] || die CONTROLLER_ALREADY_EXISTS 69
  INPUT_NONCE=''
  read_enrollment_input
  [ "$INPUT_ROLE" = controller ] || die FIRST_DEVICE_MUST_BE_CONTROLLER 69
  register_device "$INPUT_PUBLIC" "$INPUT_LABEL" "$INPUT_ROLE" "$DEVICE_ID"
  printf '__PNA_DEVICE_BOOTSTRAP_V1_BEGIN__\nDEVICE_ID=%s\nROLE=controller\nSTATUS=active\n__PNA_DEVICE_BOOTSTRAP_V1_END__\n' "$DEVICE_ID"
}

create_invite() {
  local controller_id="${1:-}" nonce hash expires now
  init_registry
  jq -e --arg id "$controller_id" 'any(.devices[]?; .deviceId==$id and .role=="controller" and .status=="active")' "$REGISTRY" >/dev/null || die ACTIVE_CONTROLLER_REQUIRED 70
  nonce="$(openssl rand -hex 32)"
  hash="$(printf '%s' "$nonce" | sha256sum | awk '{print $1}')"
  now="$(date +%s)"; expires=$((now + 600))
  write_registry '.invites |= map(select((.used // false)==false and .expires>$now)) | .invites += [{nonceSha256:$hash,createdBy:$controller,expires:$expires,used:false}]' \
    --arg hash "$hash" --arg controller "$controller_id" --argjson expires "$expires" --argjson now "$now"
  printf '__PNA_DEVICE_INVITE_V1_BEGIN__\nENROLLMENT_NONCE=%s\nEXPIRES_EPOCH=%s\nNODE_ID=%s\n__PNA_DEVICE_INVITE_V1_END__\n' \
    "$nonce" "$expires" "$(jq -r '.nodeId' "$REGISTRY")"
}

enroll_device() {
  local hash now index
  init_registry
  read_enrollment_input
  [[ "${INPUT_NONCE:-}" =~ ^[0-9a-f]{64}$ ]] || die NONCE_INVALID 71
	verify_enrollment_signature "$(jq -r '.nodeId' "$REGISTRY")" "$INPUT_NONCE" "$DEVICE_ID" "$INPUT_PUBLIC" "$INPUT_LABEL" "$INPUT_ROLE" "${INPUT_SIGNATURE:-}"
  hash="$(printf '%s' "$INPUT_NONCE" | sha256sum | awk '{print $1}')"
  now="$(date +%s)"
  index="$(jq -r --arg hash "$hash" --argjson now "$now" '.invites | to_entries[]? | select(.value.nonceSha256==$hash and .value.used==false and .value.expires>=$now) | .key' "$REGISTRY" | sed -n '1p')"
  [[ "$index" =~ ^[0-9]+$ ]] || die NONCE_EXPIRED_OR_USED 71
  register_device "$INPUT_PUBLIC" "$INPUT_LABEL" "$INPUT_ROLE" "$DEVICE_ID" "$index"
  printf '__PNA_DEVICE_ENROLL_V1_BEGIN__\nDEVICE_ID=%s\nROLE=%s\nSTATUS=active\nNONCE_CONSUMED=1\n__PNA_DEVICE_ENROLL_V1_END__\n' "$DEVICE_ID" "$INPUT_ROLE"
}

require_active_controller() {
  local id="$1"
  jq -e --arg id "$id" 'any(.devices[]?; .deviceId==$id and .role=="controller" and .status=="active")' "$REGISTRY" >/dev/null || die ACTIVE_CONTROLLER_REQUIRED 70
}

change_device_state() {
  local action="$1" controller="$2" target="$3" role active_controllers
  init_registry
  require_active_controller "$controller"
  jq -e --arg id "$target" 'any(.devices[]?; .deviceId==$id and .status!="revoked")' "$REGISTRY" >/dev/null || die TARGET_DEVICE_NOT_ACTIVE 72
  role="$(jq -r --arg id "$target" '.devices[] | select(.deviceId==$id) | .role' "$REGISTRY")"
  active_controllers="$(jq '[.devices[] | select(.role=="controller" and .status=="active")] | length' "$REGISTRY")"
  if [ "$role" = controller ] && [ "$active_controllers" -le 1 ] && [ "$action" != resume ]; then die LAST_CONTROLLER_PROTECTED 73; fi
  case "$action" in
    pause) set_device_enabled "$target" false ;;
    resume) set_device_enabled "$target" true ;;
    revoke) delete_device_clients "$target" ;;
    *) die INVALID_STATE_ACTION 2 ;;
  esac
  printf '__PNA_DEVICE_STATE_V1_BEGIN__\nDEVICE_ID=%s\nSTATUS=%s\n__PNA_DEVICE_STATE_V1_END__\n' "$target" "$([ "$action" = revoke ] && echo revoked || { [ "$action" = pause ] && echo paused || echo active; })"
}

device_handoff() {
  local id="$1" device uuid domain public reality reality_key short_id direct_link xhttp path xhttp_link=''
  init_registry
  device="$(jq -c --arg id "$id" '.devices[]? | select(.deviceId==$id and .status=="active")' "$REGISTRY")"
  [ -n "$device" ] || die ACTIVE_DEVICE_NOT_FOUND 74
  uuid="$(jq -r '.vlessUuid' <<< "$device")"
  domain="$(sed -n 's/^COVER_DOMAIN=//p' /etc/proxy-runbook/public.env 2>/dev/null | sed -n '1p')"
  public="$(sed -n 's/^PUBLIC_IP=//p' /etc/proxy-runbook/public.env 2>/dev/null | sed -n '1p')"
  reality="$(get_reality)"
  [ -n "$domain" ] && [ -n "$public" ] && [ -n "$reality" ] || die HANDOFF_CONTEXT_MISSING 74
  reality_key="$(jq -r '.streamSettings.realitySettings.settings.publicKey // .streamSettings.realitySettings.settings.password // empty' <<< "$reality")"
  short_id="$(jq -r '.streamSettings.realitySettings.shortIds[0] // empty' <<< "$reality")"
  direct_link="vless://${uuid}@${public}:443?type=tcp&security=reality&pbk=$(jq -rn --arg v "$reality_key" '$v|@uri')&fp=chrome&sni=$(jq -rn --arg v "$domain" '$v|@uri')&sid=$(jq -rn --arg v "$short_id" '$v|@uri')&spx=%2F&flow=xtls-rprx-vision#$(jq -rn --arg v "$id" '$v|@uri')"
  xhttp="$(get_xhttp)"
  if [ -n "$xhttp" ] && jq -e --arg uuid "$uuid" 'any(.settings.clients[]?; .id==$uuid and .enable==true)' <<< "$xhttp" >/dev/null; then
    path="$(jq -r '.streamSettings.xhttpSettings.path // empty' <<< "$xhttp")"
    xhttp_link="vless://${uuid}@${domain}:443?encryption=none&security=tls&sni=$(jq -rn --arg v "$domain" '$v|@uri')&fp=chrome&type=xhttp&host=$(jq -rn --arg v "$domain" '$v|@uri')&path=$(jq -rn --arg v "$path" '$v|@uri')&mode=packet-up#$(jq -rn --arg v "${id}-cdn" '$v|@uri')"
  fi
  echo '__PNA_DEVICE_HANDOFF_V1_BEGIN__'
  printf 'DEVICE_ID=%s\nDEVICE_ROLE=%s\nDIRECT_REALITY_LINK=%s\n' "$id" "$(jq -r '.role' <<< "$device")" "$direct_link"
  [ -z "$xhttp_link" ] || printf 'CDN_XHTTP_LINK=%s\n' "$xhttp_link"
  echo '__PNA_DEVICE_HANDOFF_V1_END__'
}

init_registry
case "$COMMAND" in
  status) [ "$#" -eq 0 ] || die USAGE 2; status_registry ;;
  bootstrap-controller) [ "$#" -eq 0 ] || die USAGE 2; bootstrap_controller ;;
  create-invite) [ "$#" -eq 1 ] || die USAGE 2; create_invite "$1" ;;
  enroll) [ "$#" -eq 0 ] || die USAGE 2; enroll_device ;;
  pause|resume|revoke) [ "$#" -eq 2 ] || die USAGE 2; change_device_state "$COMMAND" "$1" "$2" ;;
  handoff) [ "$#" -eq 1 ] || die USAGE 2; device_handoff "$1" ;;
  *) die USAGE 2 ;;
esac
