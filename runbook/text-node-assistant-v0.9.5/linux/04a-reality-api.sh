#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib-xui-api.sh
. "$ROOT/linux/lib-xui-api.sh"
. "$ROOT/linux/lib-handoff.sh"

cmd="${1:-}"
shift || true

xui_api_context || { echo "ERROR: cannot obtain local 3x-ui API context."; exit 1; }
command -v jq >/dev/null || { echo "jq missing."; exit 1; }

uri() { jq -rn --arg v "$1" '$v|@uri'; }

list_inbounds() {
  xui_api_get "/panel/api/inbounds/list"
}

get_by_port() {
  local port="$1"
  list_inbounds | jq -c --argjson p "$port" '.obj[]? | select(.port==$p)' | sed -n '1p'
}

create_test() {
  local domain="$1" ip="$2" port="${3:-24443}"
  [ -n "$domain" ] && [ -n "$ip" ] || { echo "usage: create-test DOMAIN PUBLIC_IP [PORT]"; exit 1; }

  if [ -n "$(get_by_port "$port")" ]; then
    echo "ERROR: inbound port $port already exists; refusing to overwrite."
    exit 1
  fi

  local key_resp uuid private_key public_key short_id sub_id email payload resp id
  uuid="$(xui_new_uuid)"
  key_resp="$(xui_api_get "/panel/api/server/getNewX25519Cert")"
  private_key="$(jq -r '.obj.privateKey // empty' <<<"$key_resp")"
  public_key="$(jq -r '.obj.publicKey // .obj.password // empty' <<<"$key_resp")"
  [ -n "$uuid" ] && [ -n "$private_key" ] && [ -n "$public_key" ] || {
    echo "ERROR: 3x-ui credential generation failed."
    exit 1
  }

  short_id="$(openssl rand -hex 8)"
  sub_id="$(openssl rand -hex 16)"
  email="self-$(date +%Y%m%d%H%M%S)"

  payload="$(jq -nc \
    --arg uuid "$uuid" --arg email "$email" --arg sub "$sub_id" \
    --arg domain "$domain" --arg ip "$ip" --arg private "$private_key" --arg public "$public_key" \
    --arg sid "$short_id" --argjson port "$port" \
    '{
      enable:true,remark:("reality-shadow-"+($port|tostring)),listen:"",port:$port,protocol:"vless",
      shareAddrStrategy:"custom",shareAddr:$ip,
      expiryTime:0,total:0,
      settings:{
        clients:[{id:$uuid,email:$email,flow:"xtls-rprx-vision",limitIp:0,totalGB:0,expiryTime:0,enable:true,tgId:0,subId:$sub,comment:"proxy-runbook-v0.6"}],
        decryption:"none",encryption:"none",fallbacks:[]
      },
      streamSettings:{
        network:"tcp",security:"reality",
        tcpSettings:{acceptProxyProtocol:false,header:{type:"none"}},
        realitySettings:{
          show:false,xver:0,target:"127.0.0.1:8443",serverNames:[$domain],
          privateKey:$private,minClientVer:"",maxClientVer:"",maxTimediff:0,shortIds:[$sid],
          settings:{publicKey:$public,fingerprint:"chrome",serverName:"",spiderX:"/"}
        }
      },
      sniffing:{enabled:true,destOverride:["http","tls"],metadataOnly:false,routeOnly:false}
    }')"

  resp="$(xui_api_post_json "/panel/api/inbounds/add" "$payload")"
  jq -e '.success == true' <<<"$resp" >/dev/null || {
    echo "ERROR creating inbound:"
    jq '{success,msg}' <<<"$resp"
    exit 1
  }
  id="$(jq -r '.obj.id // empty' <<<"$resp")"

  local link
  link="vless://${uuid}@${ip}:${port}?type=tcp&security=reality&pbk=$(uri "$public_key")&fp=chrome&sni=$(uri "$domain")&sid=$(uri "$short_id")&spx=%2F&flow=xtls-rprx-vision#$(uri "self-reality-shadow-${port}")"

  install -d -m 700 /root/.config/proxy-runbook
  {
    echo "INBOUND_ID=${id}"
    echo "TEST_PORT=${port}"
    echo "DOMAIN=${domain}"
    echo "PUBLIC_IP=${ip}"
    echo "UUID=${uuid}"
    echo "REALITY_PRIVATE_KEY=${private_key}"
    echo "REALITY_PUBLIC_KEY=${public_key}"
    echo "SHORT_ID=${short_id}"
    echo "SUB_ID=${sub_id}"
    echo "CLIENT_LINK=${link}"
  } > /root/.config/proxy-runbook/reality-shadow.env
  chmod 600 /root/.config/proxy-runbook/reality-shadow.env

  handoff_set "REALITY_TEST_UUID" "$uuid"
  handoff_set "REALITY_PRIVATE_KEY" "$private_key"
  handoff_set "REALITY_PUBLIC_KEY" "$public_key"
  handoff_set "REALITY_SHORT_ID" "$short_id"
  handoff_set "REALITY_TEST_SUB_ID" "$sub_id"
  handoff_set "REALITY_TEST_LINK" "$link"

  echo "REALITY_SHADOW_CREATED id=${id} port=${port}"
  echo
  echo "================ REAL GENERATED REALITY KEYS ============"
  echo "UUID=$uuid"
  echo "REALITY_PRIVATE_KEY=$private_key"
  echo "REALITY_PUBLIC_KEY=$public_key"
  echo "SHORT_ID=$short_id"
  echo "SUB_ID=$sub_id"
  echo "========================================================="
  echo "=== TEST CLIENT LINK ==="
  echo "$link"
  echo
  echo "PrivateKey is intentionally shown in full for credential handoff."
  echo "It stays server-side; never put PrivateKey in the client."
  echo "Root-only copy: /root/.config/proxy-runbook/reality-shadow.env"

  private_key=""
  unset private_key
}

promote_shadow() {
  local port="${1:-24443}" prod="${2:-443}"
  local obj id payload resp ip domain link uuid public_key short_id
  obj="$(get_by_port "$port")"
  [ -n "$obj" ] || { echo "ERROR: no inbound on $port."; exit 1; }
  if [ -n "$(get_by_port "$prod")" ]; then
    echo "ERROR: production port $prod already exists. Refusing to overwrite."
    exit 1
  fi
  id="$(jq -r '.id' <<<"$obj")"
  ip="${PUBLIC_IP:-$(curl -4fsS --max-time 8 https://api.ipify.org)}"
  payload="$(jq -c --argjson p "$prod" --arg ip "$ip" \
    '{enable,remark,listen,protocol,expiryTime,total,settings,streamSettings,sniffing,
      subSortIndex,trafficReset,trafficResetDay,shareAddrStrategy,shareAddr}
     | .port=$p
     | .remark="reality-production-443"
     | .shareAddrStrategy="custom"
     | .shareAddr=$ip' <<<"$obj")"
  resp="$(xui_api_post_json "/panel/api/inbounds/update/${id}" "$payload")"
  jq -e '.success == true' <<<"$resp" >/dev/null || {
    echo "ERROR promoting inbound:"
    jq '{success,msg}' <<<"$resp"; exit 1;
  }

  obj="$(get_by_port "$prod")"
  domain="$(jq -r '.streamSettings.realitySettings.serverNames[0] // empty' <<<"$obj")"
  uuid="$(jq -r '.settings.clients[0].id // empty' <<<"$obj")"
  public_key="$(jq -r '.streamSettings.realitySettings.settings.publicKey // .streamSettings.realitySettings.settings.password // empty' <<<"$obj")"
  short_id="$(jq -r '.streamSettings.realitySettings.shortIds[0] // empty' <<<"$obj")"
  link="vless://${uuid}@${ip}:${prod}?type=tcp&security=reality&pbk=$(uri "$public_key")&fp=chrome&sni=$(uri "$domain")&sid=$(uri "$short_id")&spx=%2F&flow=xtls-rprx-vision#$(uri "self-reality-443")"

  echo "$link" > /root/proxy-node-client-link.txt
  chmod 600 /root/proxy-node-client-link.txt
  handoff_set "REALITY_PRODUCTION_LINK" "$link"
  echo "REALITY_PROMOTED id=${id} ${port}->${prod}"
  echo
  echo "=== PRODUCTION CLIENT LINK ==="
  echo "$link"
  echo
  echo "Saved root-only: /root/proxy-node-client-link.txt"
}

show_shadow() {
  local port="${1:-24443}" state="/root/.config/proxy-runbook/reality-shadow.env"
  local saved_port link obj
  [ -s "$state" ] || return 1
  # create-test has historically persisted TEST_PORT.  A short-lived v0.9.0
  # reuse probe looked only for PORT, so a valid shadow from an interrupted run
  # was mistaken for an unrelated listener and create-test then refused to
  # overwrite it.  Accept both spellings while still verifying the real inbound
  # below before disclosing or reusing the saved link.
  saved_port="$(sed -n -E 's/^(TEST_PORT|PORT)=//p' "$state" | sed -n '1p')"
  link="$(sed -n 's/^CLIENT_LINK=//p' "$state" | sed -n '1p')"
  [ "$saved_port" = "$port" ] && [ -n "$link" ] || return 1
  obj="$(get_by_port "$port")"
  [ -n "$obj" ] || return 1
  [ "$(jq -r '.protocol // empty' <<<"$obj")" = "vless" ] || return 1
  [ "$(jq -r '.streamSettings.security // empty' <<<"$obj")" = "reality" ] || return 1
  echo "REALITY_SHADOW_REUSABLE port=$port"
  echo "=== EXISTING TEST CLIENT LINK ==="
  echo "$link"
}

inspect_443() {
  local expected_domain="${1:-}"
  local expected_ip="${2:-}"
  local obj target domain security protocol share_strategy share_address
  obj="$(get_by_port 443)"
  if [ -z "$obj" ]; then
    echo "NO_443_INBOUND"
    exit 2
  fi
  protocol="$(jq -r '.protocol // empty' <<<"$obj")"
  security="$(jq -r '.streamSettings.security // empty' <<<"$obj")"
  target="$(jq -r '.streamSettings.realitySettings.target // .streamSettings.realitySettings.dest // empty' <<<"$obj")"
  domain="$(jq -r '.streamSettings.realitySettings.serverNames[0] // empty' <<<"$obj")"
  share_strategy="$(jq -r '.shareAddrStrategy // empty' <<<"$obj")"
  share_address="$(jq -r '.shareAddr // empty' <<<"$obj")"
  echo "PORT443 protocol=${protocol} security=${security} target=${target} serverName=${domain} shareStrategy=${share_strategy} shareAddress=${share_address}"
  if [ "$protocol" = "vless" ] && [ "$security" = "reality" ] && [ "$target" = "127.0.0.1:8443" ]; then
    if [ -z "$expected_domain" ] || [ "$domain" = "$expected_domain" ]; then
      if [ "$share_strategy" != "custom" ] || [ -z "$share_address" ] || \
         { [ -n "$expected_ip" ] && [ "$share_address" != "$expected_ip" ]; }; then
        echo "REALITY_443_SHARE_ADDRESS_DRIFT"
        exit 4
      fi
      echo "REALITY_443_OPTIMAL"
      exit 0
    fi
  fi
  echo "REALITY_443_DRIFT"
  exit 3
}

normalize_share() {
  local ip="${1:-}" obj id payload resp now
  [ -n "$ip" ] || { echo "usage: normalize-share PUBLIC_IP"; exit 1; }
  obj="$(get_by_port 443)"
  [ -n "$obj" ] || { echo "ERROR: no inbound on 443."; exit 1; }
  [ "$(jq -r '.protocol // empty' <<<"$obj")" = "vless" ] || { echo "ERROR: 443 is not VLESS."; exit 1; }
  [ "$(jq -r '.streamSettings.security // empty' <<<"$obj")" = "reality" ] || { echo "ERROR: 443 is not REALITY."; exit 1; }
  id="$(jq -r '.id' <<<"$obj")"
  payload="$(jq -c --arg ip "$ip" '
    {enable,remark,listen,port,protocol,expiryTime,total,settings,streamSettings,sniffing,
     subSortIndex,trafficReset,trafficResetDay,shareAddrStrategy,shareAddr}
    | .shareAddrStrategy="custom"
    | .shareAddr=$ip
  ' <<<"$obj")"
  resp="$(xui_api_post_json "/panel/api/inbounds/update/${id}" "$payload")"
  jq -e '.success == true' <<<"$resp" >/dev/null || {
    echo "ERROR normalizing subscription share address:"
    jq '{success,msg}' <<<"$resp"
    exit 1
  }
  now="$(get_by_port 443)"
  [ "$(jq -r '.shareAddrStrategy // empty' <<<"$now")" = "custom" ] && \
    [ "$(jq -r '.shareAddr // empty' <<<"$now")" = "$ip" ] || {
      echo "ERROR: share address update did not persist."
      exit 1
    }
  echo "REALITY_443_SHARE_ADDRESS_NORMALIZED"
}

case "$cmd" in
  create-test) create_test "$@" ;;
  show-shadow) show_shadow "$@" ;;
  promote-shadow) promote_shadow "$@" ;;
  inspect-443) inspect_443 "$@" ;;
  normalize-share) normalize_share "$@" ;;
  list) list_inbounds | jq '.obj | map({id,remark,port,protocol,enable,shareAddrStrategy,shareAddr,security:.streamSettings.security,target:(.streamSettings.realitySettings.target // .streamSettings.realitySettings.dest)})' ;;
  *) echo "usage: $0 {create-test DOMAIN PUBLIC_IP [PORT]|show-shadow [PORT]|promote-shadow [TEST_PORT] [PROD_PORT]|inspect-443 [EXPECTED_DOMAIN] [EXPECTED_IP]|normalize-share PUBLIC_IP|list}"; exit 1 ;;
esac
