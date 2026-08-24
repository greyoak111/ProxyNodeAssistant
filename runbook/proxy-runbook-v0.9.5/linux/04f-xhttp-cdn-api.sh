#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/linux/lib-xui-api.sh"
. "$ROOT/linux/lib-handoff.sh"

STATE_DIR="/root/.config/proxy-runbook"
STATE_FILE="$STATE_DIR/cdn-xhttp.env"
REMARK="pna-cdn-xhttp"

[ "$(id -u)" -eq 0 ] || { echo 'ERROR: run as root.' >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo 'ERROR: jq is required.' >&2; exit 1; }
xui_api_context || { echo 'ERROR: cannot obtain local 3x-ui API context.' >&2; exit 1; }

uri() { jq -rn --arg v "$1" '$v|@uri'; }
list_inbounds() { xui_api_get '/panel/api/inbounds/list'; }
get_by_port() {
  local port="$1"
  list_inbounds | jq -c --argjson p "$port" '.obj[]? | select(.port==$p)' | sed -n '1p'
}
get_managed() {
  list_inbounds | jq -c --arg r "$REMARK" '.obj[]? | select(.remark==$r)' | sed -n '1p'
}
state_value() {
  local key="$1" line
  [ -r "$STATE_FILE" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in "${key}="*) printf '%s\n' "${line#*=}"; return 0;; esac
  done < "$STATE_FILE"
  return 1
}

valid_domain() {
  [[ "${1:-}" =~ ^([A-Za-z0-9][A-Za-z0-9-]*\.)+[A-Za-z]{2,63}$ ]]
}

verify_object() {
  local object="$1" expected_port="$2" expected_path="$3" expected_uuid="$4"
  [ -n "$object" ] || { echo 'PNA_XHTTP_ERROR=INBOUND_MISSING' >&2; return 91; }
  jq -e \
    --arg remark "$REMARK" --arg path "$expected_path" --arg uuid "$expected_uuid" --argjson port "$expected_port" \
    '.enable == true and .remark == $remark and .listen == "127.0.0.1" and .port == $port and
     .protocol == "vless" and .settings.decryption == "none" and .settings.encryption == "none" and
     (.settings.fallbacks | type == "array" and length == 0) and
     (.settings.clients | type == "array" and length >= 1) and
     .settings.clients[0].id == $uuid and (.settings.clients[0].flow // "") == "" and
     .streamSettings.network == "xhttp" and .streamSettings.security == "none" and
     .streamSettings.xhttpSettings.path == $path and
     .streamSettings.xhttpSettings.mode == "packet-up"' <<<"$object" >/dev/null || {
       echo 'PNA_XHTTP_ERROR=READBACK_MISMATCH' >&2
       return 92
     }
}

runtime_verify() {
  local port="$1" line
  systemctl is-active --quiet x-ui || { echo 'PNA_XHTTP_ERROR=XUI_INACTIVE' >&2; return 93; }
  line="$(ss -lntp 2>/dev/null | awk -v p=":${port}" '$4 ~ ("127\\.0\\.0\\.1" p "$") {print; exit}')"
  [ -n "$line" ] || { echo "PNA_XHTTP_ERROR=LOOPBACK_LISTENER_MISSING port=$port" >&2; return 93; }
  if ss -lntp 2>/dev/null | awk -v p=":${port}" '$4 ~ ("0\\.0\\.0\\.0" p "$|\\[::\\]" p "$") {found=1} END{exit !found}'; then
    echo "PNA_XHTTP_ERROR=PUBLIC_LISTENER port=$port" >&2
    return 94
  fi
}

show_managed() {
  local port path uuid object
  [ -r "$STATE_FILE" ] || { echo 'PNA_XHTTP_ERROR=STATE_MISSING' >&2; return 95; }
  port="$(state_value XHTTP_LOCAL_PORT || true)"
  path="$(state_value XHTTP_PATH || true)"
  uuid="$(state_value XHTTP_UUID || true)"
  case "$port" in ''|*[!0-9]*) echo 'PNA_XHTTP_ERROR=STATE_PORT_INVALID' >&2; return 95;; esac
  object="$(get_by_port "$port")"
  verify_object "$object" "$port" "$path" "$uuid"
  runtime_verify "$port"
  printf '__PNA_XHTTP_STATE_BEGIN__\n'
  printf 'XHTTP_STATUS=READY\nXHTTP_INBOUND_ID=%s\nXHTTP_LOCAL_PORT=%s\nXHTTP_PATH=%s\nXHTTP_LISTEN=127.0.0.1\nXHTTP_MODE=packet-up\n' \
    "$(jq -r '.id' <<<"$object")" "$port" "$path"
  printf '__PNA_XHTTP_STATE_END__\n'
}

create_managed() {
  local domain="$1" existing stored_domain port='' candidate uuid path sub_id email payload response object id tmp attempt
  valid_domain "$domain" || { echo 'PNA_XHTTP_ERROR=DOMAIN_INVALID' >&2; return 96; }
  if [ -s "$STATE_FILE" ]; then
    stored_domain="$(state_value XHTTP_DOMAIN || true)"
    [ "$stored_domain" = "$domain" ] || {
      echo 'PNA_XHTTP_ERROR=EXISTING_DOMAIN_MISMATCH' >&2
      return 97
    }
    show_managed
    echo 'PNA_XHTTP_ALREADY_READY'
    return 0
  fi
  existing="$(get_managed)"
  [ -z "$existing" ] || { echo 'PNA_XHTTP_ERROR=UNCLAIMED_MANAGED_REMARK' >&2; return 97; }

  for attempt in $(seq 1 64); do
    candidate="$(shuf -i 30000-39999 -n 1)"
    [ -z "$(get_by_port "$candidate")" ] || continue
    ss -lnt 2>/dev/null | awk -v p=":${candidate}" '$4 ~ (p "$") {found=1} END{exit found ? 0 : 1}' && continue
    port="$candidate"
    break
  done
  [ -n "$port" ] || { echo 'PNA_XHTTP_ERROR=NO_FREE_LOOPBACK_PORT' >&2; return 98; }

  uuid="$(xui_new_uuid)"
  path="/$(openssl rand -hex 16)/"
  sub_id="$(openssl rand -hex 16)"
  email="pna-cdn-$(date +%Y%m%d%H%M%S)"
  payload="$(jq -nc \
    --arg remark "$REMARK" --arg uuid "$uuid" --arg email "$email" --arg sub "$sub_id" \
    --arg path "$path" --argjson port "$port" \
    '{enable:true,remark:$remark,listen:"127.0.0.1",port:$port,protocol:"vless",
      expiryTime:0,total:0,shareAddrStrategy:"custom",shareAddr:"",
      settings:{clients:[{id:$uuid,email:$email,flow:"",limitIp:0,totalGB:0,expiryTime:0,enable:true,tgId:0,subId:$sub,comment:"pna-cdn-xhttp-v0.9.5"}],decryption:"none",encryption:"none",fallbacks:[]},
      streamSettings:{network:"xhttp",security:"none",xhttpSettings:{path:$path,host:"",mode:"packet-up"}},
      sniffing:{enabled:true,destOverride:["http","tls","quic"],metadataOnly:false,routeOnly:false}}')"
  response="$(xui_api_post_json '/panel/api/inbounds/add' "$payload")"
  jq -e '.success == true' <<<"$response" >/dev/null || { jq '{success,msg}' <<<"$response" >&2; return 99; }

  object="$(get_by_port "$port")"
  verify_object "$object" "$port" "$path" "$uuid" || {
    echo 'PNA_XHTTP_ERROR=CREATED_BUT_READBACK_FAILED' >&2
    return 100
  }
  id="$(jq -r '.id // empty' <<<"$object")"
  case "$id" in ''|*[!0-9]*) echo 'PNA_XHTTP_ERROR=INBOUND_ID_INVALID' >&2; return 100;; esac
  runtime_verify "$port"

  install -d -m 700 "$STATE_DIR"
  tmp="$(mktemp "${STATE_DIR}/.cdn-xhttp.XXXXXX")"
  {
    printf 'XHTTP_INBOUND_ID=%s\n' "$id"
    printf 'XHTTP_LOCAL_PORT=%s\n' "$port"
    printf 'XHTTP_PATH=%s\n' "$path"
    printf 'XHTTP_UUID=%s\n' "$uuid"
    printf 'XHTTP_SUB_ID=%s\n' "$sub_id"
    printf 'XHTTP_DOMAIN=%s\n' "$domain"
    printf 'XHTTP_MODE=packet-up\n'
  } > "$tmp"
  chmod 600 "$tmp"
  mv -f -- "$tmp" "$STATE_FILE"
  handoff_set CDN_XHTTP_UUID "$uuid"
  handoff_set CDN_XHTTP_PATH "$path"
  handoff_set CDN_XHTTP_LOCAL_PORT "$port"
  echo "PNA_XHTTP_CREATED id=$id port=$port listen=127.0.0.1 mode=packet-up"
  show_managed
}

build_link() {
  local domain="$1" public_port="${2:-443}" port path uuid stored_domain object encoded_path link label
  valid_domain "$domain" || { echo 'PNA_XHTTP_ERROR=DOMAIN_INVALID' >&2; return 96; }
  case "$public_port" in 443|8443) ;; *) echo 'PNA_XHTTP_ERROR=PUBLIC_PORT_NOT_ALLOWED' >&2; return 101;; esac
  stored_domain="$(state_value XHTTP_DOMAIN || true)"
  [ "$stored_domain" = "$domain" ] || { echo 'PNA_XHTTP_ERROR=STATE_DOMAIN_MISMATCH' >&2; return 101; }
  port="$(state_value XHTTP_LOCAL_PORT || true)"
  path="$(state_value XHTTP_PATH || true)"
  uuid="$(state_value XHTTP_UUID || true)"
  object="$(get_by_port "$port")"
  verify_object "$object" "$port" "$path" "$uuid"
  runtime_verify "$port"
  encoded_path="$(uri "$path")"
  if [ "$public_port" = 8443 ]; then label='PNA-CDN-XHTTP-STAGE'; else label='PNA-CDN-XHTTP'; fi
  link="vless://${uuid}@${domain}:${public_port}?encryption=none&security=tls&sni=$(uri "$domain")&fp=chrome&type=xhttp&host=$(uri "$domain")&path=${encoded_path}&mode=packet-up#$(uri "$label")"
  case "$public_port" in
    443) handoff_set CDN_XHTTP_LINK "$link" ;;
    8443) handoff_set CDN_XHTTP_STAGE_LINK "$link" ;;
  esac
  printf '__PNA_XHTTP_LINK_BEGIN__\n'
  printf 'XHTTP_PUBLIC_PORT=%s\nXHTTP_LINK=%s\n' "$public_port" "$link"
  printf '__PNA_XHTTP_LINK_END__\n'
}

delete_managed() {
  local port path uuid object id response
  [ -s "$STATE_FILE" ] || { echo 'PNA_XHTTP_NOT_INSTALLED'; return 0; }
  port="$(state_value XHTTP_LOCAL_PORT || true)"
  path="$(state_value XHTTP_PATH || true)"
  uuid="$(state_value XHTTP_UUID || true)"
  object="$(get_by_port "$port")"
  verify_object "$object" "$port" "$path" "$uuid"
  id="$(jq -r '.id' <<<"$object")"
  response="$(xui_auth_curl -X POST "${XUI_BASE}/panel/api/inbounds/del/${id}")"
  jq -e '.success == true' <<<"$response" >/dev/null || { jq '{success,msg}' <<<"$response" >&2; return 102; }
  [ -z "$(get_by_port "$port")" ] || { echo 'PNA_XHTTP_ERROR=DELETE_READBACK_FAILED' >&2; return 102; }
  rm -f -- "$STATE_FILE"
  handoff_delete CDN_XHTTP_UUID
  handoff_delete CDN_XHTTP_PATH
  handoff_delete CDN_XHTTP_LOCAL_PORT
  handoff_delete CDN_XHTTP_LINK
  handoff_delete CDN_XHTTP_STAGE_LINK
  echo "PNA_XHTTP_DELETED id=$id port=$port"
}

case "${1:-}" in
  create) [ "$#" -eq 2 ] || { echo 'usage: create DOMAIN' >&2; exit 2; }; create_managed "$2" ;;
  show) [ "$#" -eq 1 ] || exit 2; show_managed ;;
  link) [ "$#" -ge 2 ] && [ "$#" -le 3 ] || { echo 'usage: link DOMAIN [443|8443]' >&2; exit 2; }; build_link "$2" "${3:-443}" ;;
  delete) [ "$#" -eq 1 ] || exit 2; delete_managed ;;
  *) echo 'usage: 04f-xhttp-cdn-api.sh create DOMAIN | show | link DOMAIN [443|8443] | delete' >&2; exit 2 ;;
esac
