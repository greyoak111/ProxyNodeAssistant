#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/linux/lib-xui-api.sh"
. "$ROOT/linux/lib-handoff.sh"

STATE_DIR="/root/.config/text-node-assistant"
STATE_FILE="$STATE_DIR/cdn-xhttp.env"
# v0.9.x used text-node-assistant; reset-line installs may have already
# migrated this state below proxy-runbook.  Prefer an explicitly requested
# directory, otherwise select whichever managed state exists.  Keeping the
# legacy default preserves old scripts and in-place upgrades.
if [ -n "${PNA_XHTTP_STATE_DIR:-}" ]; then
  STATE_DIR="$PNA_XHTTP_STATE_DIR"
  STATE_FILE="$STATE_DIR/cdn-xhttp.env"
elif [ ! -r "$STATE_FILE" ] && [ -r /root/.config/proxy-runbook/cdn-xhttp.env ]; then
  STATE_DIR="/root/.config/proxy-runbook"
  STATE_FILE="$STATE_DIR/cdn-xhttp.env"
fi
# v1 owns the PNA-labelled profile.  The text-node-assistant spelling is kept
# as an exact import/migration alias so an in-place upgrade can repair an old
# inbound without creating a second XHTTP listener.  Nothing new is emitted
# with a TNA or v0.9.5 label.
REMARK="pna-cdn-xhttp"
LEGACY_REMARK="tna-cdn-xhttp"
EXTERNAL_PROXY_REMARK="pna-cdn-xhttp-orange"
LEGACY_EXTERNAL_PROXY_REMARK="tna-cdn-xhttp-orange"
CLIENT_COMMENT="pna-cdn-xhttp-v1.0.0"

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
  list_inbounds | jq -c --arg r "$REMARK" --arg legacy "$LEGACY_REMARK" \
    '.obj[]? | select((.remark==$r or .remark==$legacy) and .protocol=="vless" and .streamSettings.network=="xhttp")' | sed -n '1p'
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
  [ -n "$object" ] || { echo 'TNA_XHTTP_ERROR=INBOUND_MISSING' >&2; return 91; }
  jq -e \
    --arg remark "$REMARK" --arg legacy "$LEGACY_REMARK" --arg path "$expected_path" --arg uuid "$expected_uuid" --argjson port "$expected_port" \
    '.enable == true and (.remark == $remark or .remark == $legacy) and .listen == "127.0.0.1" and .port == $port and
     .protocol == "vless" and .settings.decryption == "none" and .settings.encryption == "none" and
     (.settings.fallbacks | type == "array" and length == 0) and
     (.settings.clients | type == "array" and length >= 1) and
     .settings.clients[0].id == $uuid and (.settings.clients[0].flow // "") == "" and
     .streamSettings.network == "xhttp" and .streamSettings.security == "none" and
     .streamSettings.xhttpSettings.path == $path and
     .streamSettings.xhttpSettings.mode == "packet-up"' <<<"$object" >/dev/null || {
       echo 'TNA_XHTTP_ERROR=READBACK_MISMATCH' >&2
     return 92
     }
}

external_proxy_payload() {
  local object="$1" domain="$2" public_port="${3:-8443}"
  jq -c --arg domain "$domain" --argjson public_port "$public_port" --arg remark "$EXTERNAL_PROXY_REMARK" --arg inbound_remark "$REMARK" --arg client_comment "$CLIENT_COMMENT" '
    {enable,remark:$inbound_remark,listen,port,protocol,expiryTime,total,settings,streamSettings,sniffing,
     tag,allocate,subSortIndex,trafficReset,trafficResetDay,shareAddrStrategy,shareAddr}
    # The loopback inbound intentionally has stream security=none.  The
    # external proxy is a separate public TLS endpoint, so `same` would make
    # 3x-ui native per-inbound share-link builder inherit `none` and emit a
    # client link without TLS/SNI/Host.  Explicitly force TLS for that public
    # endpoint; the hosts metadata below carries the same settings for APIs
    # that render links from host groups.
    # A known legacy client comment is presentation metadata, not a user
    # supplied note.  Normalize it during the same in-place repair while
    # leaving arbitrary user comments untouched.
    | .settings.clients = ((.settings.clients // []) | map(
        if ((.comment // "") == "tna-cdn-xhttp-v0.9.5" or (.comment // "") == "pna-cdn-xhttp-v0.9.5")
        then .comment=$client_comment else . end))
    | .streamSettings.externalProxy=[{forceTls:"tls",dest:$domain,port:$public_port,remark:$remark}]
  ' <<<"$object"
}

# 3x-ui 3.6+ has a supported HostGroup model which is consumed by the
# inbound-level link exporter.  Keep it in sync with the managed XHTTP
# externalProxy.  Without this record, /inbounds/allLinks and the panel's
# inbound share dialog can fall back to the loopback security=none profile.
get_host_group() {
  xui_api_get '/panel/api/hosts/list' |
    jq -c --arg group "$REMARK" --arg legacy "$LEGACY_REMARK" '.obj[]? | select(.groupId == $group or .groupId == $legacy)' |
    sed -n '1p'
}

host_group_payload() {
  local object="$1" domain="$2" public_port="$3" group_id="${4:-$REMARK}" inbound_id path
  inbound_id="$(jq -r '.id // empty' <<<"$object")"
  path="$(jq -r '.streamSettings.xhttpSettings.path // empty' <<<"$object")"
  jq -nc \
    --arg group "$group_id" --arg domain "$domain" --arg endpoint "$domain:$public_port" \
    --arg remark "$EXTERNAL_PROXY_REMARK" \
    --arg path "$path" --argjson inbound_id "$inbound_id" --argjson public_port "$public_port" \
    '{groupId:$group,inboundIds:[$inbound_id],hosts:[$endpoint],sortOrder:0,
      remark:$remark,serverDescription:"managed CDN XHTTP",
      isDisabled:false,isHidden:false,tags:[],port:$public_port,security:"tls",
      sni:$domain,hostHeader:$domain,path:$path,alpn:[],fingerprint:"chrome",
      overrideSniFromAddress:false,keepSniBlank:false,pinnedPeerCertSha256:[],
      verifyPeerCertByName:"",allowInsecure:false,echConfigList:"",muxParams:"",
      sockoptParams:"",finalMask:"",vlessRoute:"",excludeFromSubTypes:[],
      nodeGuids:[],mihomoIpVersion:"",mihomoX25519:false,shuffleHost:false}'
}

sync_host_group() {
  local domain="$1" public_port="${2:-8443}" object group group_id payload response inbound_id endpoint current
  object="$(get_managed)"
  [ -n "$object" ] || { echo 'TNA_XHTTP_ERROR=INBOUND_MISSING' >&2; return 91; }
  inbound_id="$(jq -r '.id // empty' <<<"$object")"
  case "$inbound_id" in ''|*[!0-9]*) echo 'TNA_XHTTP_ERROR=INBOUND_ID_INVALID' >&2; return 100;; esac
  endpoint="$domain:$public_port"
  group_id="$REMARK"
  group="$(get_host_group || true)"
  if [ -n "$group" ]; then
    group_id="$(jq -r '.groupId // empty' <<<"$group")"
    [ -n "$group_id" ] || group_id="$REMARK"
  fi
  payload="$(host_group_payload "$object" "$domain" "$public_port" "$group_id")"
  if [ -n "$group" ]; then
    response="$(xui_api_post_json "/panel/api/hosts/update/${group_id}" "$payload")" || {
      echo 'TNA_XHTTP_ERROR=HOST_GROUP_UPDATE_FAILED' >&2
      return 105
    }
  else
    response="$(xui_api_post_json '/panel/api/hosts/add' "$payload")" || {
      echo 'TNA_XHTTP_ERROR=HOST_GROUP_ADD_FAILED' >&2
      return 105
    }
  fi
  jq -e '.success == true' <<<"$response" >/dev/null || {
    jq '{success,msg}' <<<"$response" >&2
    echo 'TNA_XHTTP_ERROR=HOST_GROUP_UPDATE_REJECTED' >&2
    return 105
  }
  current="$(get_host_group || true)"
  jq -e --arg endpoint "$endpoint" --arg domain "$domain" --arg path "$(jq -r '.streamSettings.xhttpSettings.path' <<<"$object")" --argjson inbound_id "$inbound_id" '
      ((.inboundIds // []) | index($inbound_id)) != null and
      ((.hosts // []) | index($endpoint)) != null and
      .port == 8443 and .security == "tls" and
      .sni == $domain and .hostHeader == $domain and .path == $path and
      .fingerprint == "chrome"
    ' <<<"$current" >/dev/null || {
    echo 'TNA_XHTTP_ERROR=HOST_GROUP_READBACK_FAILED' >&2
    return 105
  }
  echo "TNA_XHTTP_HOST_GROUP_SYNCED=1 endpoint=$endpoint"
}

sync_external_proxy() {
  local domain="$1" public_port="${2:-8443}" object id local_port payload response updated
  valid_domain "$domain" || { echo 'TNA_XHTTP_ERROR=DOMAIN_INVALID' >&2; return 96; }
  [ "$public_port" = 8443 ] || { echo 'TNA_XHTTP_ERROR=PUBLIC_PORT_MUST_BE_8443' >&2; return 101; }
  object="$(get_managed)"
  [ -n "$object" ] || { echo 'TNA_XHTTP_ERROR=INBOUND_MISSING' >&2; return 91; }
  id="$(jq -r '.id // empty' <<<"$object")"
  local_port="$(jq -r '.port // empty' <<<"$object")"
  case "$id" in ''|*[!0-9]*) echo 'TNA_XHTTP_ERROR=INBOUND_ID_INVALID' >&2; return 100;; esac
  case "$local_port" in ''|*[!0-9]*) echo 'TNA_XHTTP_ERROR=INBOUND_PORT_INVALID' >&2; return 100;; esac
  if jq -e --arg domain "$domain" --argjson public_port "$public_port" '
      (.streamSettings.externalProxy // []) | length == 1 and .[0].dest == $domain and
      .[0].port == $public_port and (.[0].forceTls // "") == "tls"
    ' <<<"$object" >/dev/null 2>&1; then
    sync_host_group "$domain" "$public_port" >/dev/null
    echo "TNA_XHTTP_EXTERNAL_PROXY_ALREADY_SET=$domain port=$public_port"
    return 0
  fi
  payload="$(external_proxy_payload "$object" "$domain" "$public_port")"
  response="$(xui_api_post_json "/panel/api/inbounds/update/${id}" "$payload")" || {
    echo 'TNA_XHTTP_ERROR=EXTERNAL_PROXY_UPDATE_FAILED' >&2
    return 104
  }
  jq -e '.success == true' <<<"$response" >/dev/null || {
    jq '{success,msg}' <<<"$response" >&2
    echo 'TNA_XHTTP_ERROR=EXTERNAL_PROXY_UPDATE_REJECTED' >&2
    return 104
  }
  updated="$(get_by_port "$local_port")"
  jq -e --arg domain "$domain" --argjson public_port "$public_port" '
      (.streamSettings.externalProxy // []) | length == 1 and .[0].dest == $domain and
      .[0].port == $public_port and (.[0].forceTls // "") == "tls"
    ' <<<"$updated" >/dev/null 2>&1 || {
    echo 'TNA_XHTTP_ERROR=EXTERNAL_PROXY_READBACK_FAILED' >&2
    return 104
  }
  sync_host_group "$domain" "$public_port" >/dev/null || return $?
  echo "TNA_XHTTP_EXTERNAL_PROXY_SYNCED=1 domain=$domain port=$public_port"
}

runtime_verify() {
  local port="$1" line
  systemctl is-active --quiet x-ui || { echo 'TNA_XHTTP_ERROR=XUI_INACTIVE' >&2; return 93; }
  line="$(ss -lntp 2>/dev/null | awk -v p=":${port}" '$4 ~ ("127\\.0\\.0\\.1" p "$") {print; exit}')"
  [ -n "$line" ] || { echo "TNA_XHTTP_ERROR=LOOPBACK_LISTENER_MISSING port=$port" >&2; return 93; }
  if ss -lntp 2>/dev/null | awk -v p=":${port}" '$4 ~ ("0\\.0\\.0\\.0" p "$|\\[::\\]" p "$") {found=1} END{exit !found}'; then
    echo "TNA_XHTTP_ERROR=PUBLIC_LISTENER port=$port" >&2
    return 94
  fi
}

show_managed() {
  local port path uuid object external_domain external_port
  [ -r "$STATE_FILE" ] || { echo 'TNA_XHTTP_ERROR=STATE_MISSING' >&2; return 95; }
  port="$(state_value XHTTP_LOCAL_PORT || true)"
  path="$(state_value XHTTP_PATH || true)"
  uuid="$(state_value XHTTP_UUID || true)"
  case "$port" in ''|*[!0-9]*) echo 'TNA_XHTTP_ERROR=STATE_PORT_INVALID' >&2; return 95;; esac
  object="$(get_by_port "$port")"
  verify_object "$object" "$port" "$path" "$uuid"
  runtime_verify "$port"
  external_domain="$(jq -r '.streamSettings.externalProxy[0].dest // empty' <<<"$object")"
  external_port="$(jq -r '.streamSettings.externalProxy[0].port // empty' <<<"$object")"
  printf '__TNA_XHTTP_STATE_BEGIN__\n'
  printf 'XHTTP_STATUS=READY\nXHTTP_INBOUND_ID=%s\nXHTTP_LOCAL_PORT=%s\nXHTTP_PATH=%s\nXHTTP_LISTEN=127.0.0.1\nXHTTP_MODE=packet-up\nXHTTP_PUBLIC_DOMAIN=%s\nXHTTP_PUBLIC_PORT=%s\n' \
    "$(jq -r '.id' <<<"$object")" "$port" "$path" "$external_domain" "$external_port"
  printf '__TNA_XHTTP_STATE_END__\n'
}

retarget_managed() {
  local domain="$1" old tmp state_backup
  valid_domain "$domain" || { echo 'TNA_XHTTP_ERROR=DOMAIN_INVALID' >&2; return 96; }
  [ -s "$STATE_FILE" ] || { echo 'TNA_XHTTP_ERROR=STATE_MISSING' >&2; return 95; }
  show_managed >/dev/null
  old="$(state_value XHTTP_DOMAIN || true)"
  [ -n "$old" ] || { echo 'TNA_XHTTP_ERROR=STATE_DOMAIN_MISSING' >&2; return 95; }
  if [ "$old" = "$domain" ]; then
    sync_external_proxy "$domain" 8443 >/dev/null
    echo "TNA_XHTTP_DOMAIN_ALREADY_SET=$domain"
    return 0
  fi
  state_backup="$(mktemp "${STATE_DIR}/.cdn-xhttp-retarget-backup.XXXXXX")"
  cp -f -- "$STATE_FILE" "$state_backup"
  tmp="$(mktemp "${STATE_DIR}/.cdn-xhttp-retarget.XXXXXX")"
  awk -v domain="$domain" '
    BEGIN { seen=0 }
    /^XHTTP_DOMAIN=/ { print "XHTTP_DOMAIN=" domain; seen++; next }
    { print }
    END { if (seen != 1) exit 1 }
  ' "$STATE_FILE" > "$tmp" || { rm -f -- "$tmp"; echo 'TNA_XHTTP_ERROR=RETARGET_STATE_INVALID' >&2; return 103; }
  chmod 600 "$tmp"
  mv -f -- "$tmp" "$STATE_FILE"
  if ! sync_external_proxy "$domain" 8443 >/dev/null; then
    # If the panel accepted the new endpoint but failed the readback, put the
    # old endpoint back before restoring the local state file. This keeps the
    # remote and local domains consistent even on a partial API failure.
    sync_external_proxy "$old" 8443 >/dev/null 2>&1 || true
    mv -f -- "$state_backup" "$STATE_FILE"
    echo 'TNA_XHTTP_ERROR=RETARGET_EXTERNAL_PROXY_FAILED' >&2
    return 104
  fi
  rm -f -- "$state_backup"
  handoff_delete CDN_XHTTP_LINK
  handoff_delete CDN_XHTTP_STAGE_LINK
  show_managed >/dev/null
  printf 'TNA_XHTTP_RETARGETED=1\nXHTTP_OLD_DOMAIN=%s\nXHTTP_DOMAIN=%s\n' "$old" "$domain"
}

create_managed() {
  local domain="$1" existing stored_domain port='' candidate uuid path sub_id email payload response object id tmp attempt
  valid_domain "$domain" || { echo 'TNA_XHTTP_ERROR=DOMAIN_INVALID' >&2; return 96; }
  if [ -s "$STATE_FILE" ]; then
    stored_domain="$(state_value XHTTP_DOMAIN || true)"
    if [ "$stored_domain" != "$domain" ]; then
      retarget_managed "$domain"
      show_managed
      return 0
    fi
    sync_external_proxy "$domain" 8443 >/dev/null
    show_managed
    echo 'TNA_XHTTP_ALREADY_READY'
    return 0
  fi
  existing="$(get_managed)"
  [ -z "$existing" ] || { echo 'TNA_XHTTP_ERROR=UNCLAIMED_MANAGED_REMARK' >&2; return 97; }

  for attempt in $(seq 1 64); do
    candidate="$(shuf -i 30000-39999 -n 1)"
    [ -z "$(get_by_port "$candidate")" ] || continue
    ss -lnt 2>/dev/null | awk -v p=":${candidate}" '$4 ~ (p "$") {found=1} END{exit found ? 0 : 1}' && continue
    port="$candidate"
    break
  done
  [ -n "$port" ] || { echo 'TNA_XHTTP_ERROR=NO_FREE_LOOPBACK_PORT' >&2; return 98; }

  uuid="$(xui_new_uuid)"
  path="/$(openssl rand -hex 16)/"
  sub_id="$(openssl rand -hex 16)"
  email="pna-cdn-$(date +%Y%m%d%H%M%S)"
  payload="$(jq -nc \
    --arg remark "$REMARK" --arg uuid "$uuid" --arg email "$email" --arg sub "$sub_id" \
    --arg comment "$CLIENT_COMMENT" --arg external_remark "$EXTERNAL_PROXY_REMARK" \
    --arg domain "$domain" \
    --arg path "$path" --argjson port "$port" \
    '{enable:true,remark:$remark,listen:"127.0.0.1",port:$port,protocol:"vless",
      expiryTime:0,total:0,shareAddrStrategy:"custom",shareAddr:"",
      settings:{clients:[{id:$uuid,email:$email,flow:"",limitIp:0,totalGB:0,expiryTime:0,enable:true,tgId:0,subId:$sub,comment:$comment}],decryption:"none",encryption:"none",fallbacks:[]},
      streamSettings:{network:"xhttp",security:"none",xhttpSettings:{path:$path,host:"",mode:"packet-up"},externalProxy:[{forceTls:"tls",dest:$domain,port:8443,remark:$external_remark}]},
      sniffing:{enabled:true,destOverride:["http","tls","quic"],metadataOnly:false,routeOnly:false}}')"
  response="$(xui_api_post_json '/panel/api/inbounds/add' "$payload")"
  jq -e '.success == true' <<<"$response" >/dev/null || { jq '{success,msg}' <<<"$response" >&2; return 99; }

  object="$(get_by_port "$port")"
  verify_object "$object" "$port" "$path" "$uuid" || {
    echo 'TNA_XHTTP_ERROR=CREATED_BUT_READBACK_FAILED' >&2
    return 100
  }
  id="$(jq -r '.id // empty' <<<"$object")"
  case "$id" in ''|*[!0-9]*) echo 'TNA_XHTTP_ERROR=INBOUND_ID_INVALID' >&2; return 100;; esac
  sync_external_proxy "$domain" 8443 >/dev/null
  object="$(get_by_port "$port")"
  verify_object "$object" "$port" "$path" "$uuid"
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
    printf 'XHTTP_MODE=packet-up\nXHTTP_PUBLIC_PORT=8443\n'
  } > "$tmp"
  chmod 600 "$tmp"
  mv -f -- "$tmp" "$STATE_FILE"
  handoff_set CDN_XHTTP_UUID "$uuid"
  handoff_set CDN_XHTTP_PATH "$path"
  handoff_set CDN_XHTTP_LOCAL_PORT "$port"
  handoff_set CDN_XHTTP_SUB_ID "$sub_id"
  handoff_set CDN_XHTTP_DOMAIN "$domain"
  handoff_set CDN_XHTTP_PUBLIC_PORT 8443
  echo "TNA_XHTTP_CREATED id=$id port=$port listen=127.0.0.1 mode=packet-up"
  show_managed
}

build_link() {
  local domain="$1" public_port="${2:-8443}" port path uuid sub_id stored_domain object encoded_path link label
  valid_domain "$domain" || { echo 'TNA_XHTTP_ERROR=DOMAIN_INVALID' >&2; return 96; }
  [ "$public_port" = 8443 ] || { echo 'TNA_XHTTP_ERROR=PUBLIC_PORT_MUST_BE_8443' >&2; return 101; }
  stored_domain="$(state_value XHTTP_DOMAIN || true)"
  [ "$stored_domain" = "$domain" ] || { echo 'TNA_XHTTP_ERROR=STATE_DOMAIN_MISMATCH' >&2; return 101; }
  port="$(state_value XHTTP_LOCAL_PORT || true)"
  path="$(state_value XHTTP_PATH || true)"
  uuid="$(state_value XHTTP_UUID || true)"
  sync_external_proxy "$domain" "$public_port" >/dev/null
  object="$(get_by_port "$port")"
  verify_object "$object" "$port" "$path" "$uuid"
  runtime_verify "$port"
  encoded_path="$(uri "$path")"
  label='PNA-CDN-XHTTP-ORANGE'
  link="vless://${uuid}@${domain}:${public_port}?encryption=none&security=tls&sni=$(uri "$domain")&fp=chrome&type=xhttp&host=$(uri "$domain")&path=${encoded_path}&mode=packet-up#$(uri "$label")"
  handoff_set CDN_XHTTP_LINK "$link"
  # Keep an explicit stage alias for older handoff consumers.  The current
  # topology intentionally validates XHTTP on 8443 before any promotion.
  handoff_set CDN_XHTTP_STAGE_LINK "$link"
  sub_id="$(state_value XHTTP_SUB_ID || true)"
  if [ -n "$sub_id" ]; then
    handoff_set CDN_XHTTP_SUB_ID "$sub_id"
    handoff_set CDN_XHTTP_DOMAIN "$domain"
    handoff_set CDN_XHTTP_PUBLIC_PORT "$public_port"
    handoff_set CDN_XHTTP_SUBSCRIPTION_URL "https://${domain}/sub/${sub_id}"
    if ! grep -q '^SUBSCRIPTION_URL=' "$HANDOFF_FILE" 2>/dev/null; then
      handoff_set SUBSCRIPTION_URL "https://${domain}/sub/${sub_id}"
    fi
  fi
  printf '__TNA_XHTTP_LINK_BEGIN__\n'
  printf 'XHTTP_PUBLIC_PORT=%s\nXHTTP_LINK=%s\n' "$public_port" "$link"
  printf '__TNA_XHTTP_LINK_END__\n'
}

delete_managed() {
  local port path uuid object id response group group_id
  [ -s "$STATE_FILE" ] || { echo 'TNA_XHTTP_NOT_INSTALLED'; return 0; }
  port="$(state_value XHTTP_LOCAL_PORT || true)"
  path="$(state_value XHTTP_PATH || true)"
  uuid="$(state_value XHTTP_UUID || true)"
  object="$(get_by_port "$port")"
  verify_object "$object" "$port" "$path" "$uuid"
  id="$(jq -r '.id' <<<"$object")"
  group="$(get_host_group || true)"
  if [ -n "$group" ]; then
    group_id="$(jq -r '.groupId // empty' <<<"$group")"
    [ -n "$group_id" ] || group_id="$REMARK"
    response="$(xui_auth_curl -X POST "${XUI_BASE}/panel/api/hosts/del/${group_id}")" || {
      echo 'TNA_XHTTP_ERROR=HOST_GROUP_DELETE_FAILED' >&2
      return 102
    }
    jq -e '.success == true' <<<"$response" >/dev/null || {
      jq '{success,msg}' <<<"$response" >&2
      echo 'TNA_XHTTP_ERROR=HOST_GROUP_DELETE_REJECTED' >&2
      return 102
    }
    [ -z "$(get_host_group || true)" ] || { echo 'TNA_XHTTP_ERROR=HOST_GROUP_DELETE_READBACK_FAILED' >&2; return 102; }
  fi
  response="$(xui_auth_curl -X POST "${XUI_BASE}/panel/api/inbounds/del/${id}")"
  jq -e '.success == true' <<<"$response" >/dev/null || { jq '{success,msg}' <<<"$response" >&2; return 102; }
  [ -z "$(get_by_port "$port")" ] || { echo 'TNA_XHTTP_ERROR=DELETE_READBACK_FAILED' >&2; return 102; }
  rm -f -- "$STATE_FILE"
  handoff_delete CDN_XHTTP_UUID
  handoff_delete CDN_XHTTP_PATH
  handoff_delete CDN_XHTTP_LOCAL_PORT
  handoff_delete CDN_XHTTP_SUB_ID
  handoff_delete CDN_XHTTP_DOMAIN
  handoff_delete CDN_XHTTP_PUBLIC_PORT
  handoff_delete CDN_XHTTP_SUBSCRIPTION_URL
  handoff_delete CDN_XHTTP_LINK
  handoff_delete CDN_XHTTP_STAGE_LINK
  echo "TNA_XHTTP_DELETED id=$id port=$port"
}

case "${1:-}" in
  create) [ "$#" -eq 2 ] || { echo 'usage: create DOMAIN' >&2; exit 2; }; create_managed "$2" ;;
  show) [ "$#" -eq 1 ] || exit 2; show_managed ;;
  link) [ "$#" -ge 2 ] && [ "$#" -le 3 ] || { echo 'usage: link DOMAIN [8443]' >&2; exit 2; }; build_link "$2" "${3:-8443}" ;;
  retarget) [ "$#" -eq 2 ] || { echo 'usage: retarget DOMAIN' >&2; exit 2; }; retarget_managed "$2" ;;
  delete) [ "$#" -eq 1 ] || exit 2; delete_managed ;;
  *) echo 'usage: 04f-xhttp-cdn-api.sh create DOMAIN | show | link DOMAIN [8443] | retarget DOMAIN | delete' >&2; exit 2 ;;
esac
