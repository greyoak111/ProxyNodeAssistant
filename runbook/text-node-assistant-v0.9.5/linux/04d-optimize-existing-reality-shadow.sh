#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/linux/lib-xui-api.sh"
xui_api_context || { echo "ERROR: cannot obtain local 3x-ui API context."; exit 1; }
command -v jq >/dev/null || { echo "jq missing."; exit 1; }

CMD="${1:-}"
DOMAIN="${2:-}"
PUBLIC_IP="${3:-$(curl -4fsS --max-time 8 https://api.ipify.org 2>/dev/null || true)}"
TEST_PORT="${4:-24443}"

uri(){ jq -rn --arg v "$1" '$v|@uri'; }
list(){ xui_api_get "/panel/api/inbounds/list"; }
by_port(){ local p="$1"; list | jq -c --argjson p "$p" '.obj[]? | select(.port==$p)' | sed -n '1p'; }

print_links_from_obj() {
  local obj="$1" port="$2" label_prefix="$3"
  local domain public sid
  domain="$(jq -r '.streamSettings.realitySettings.serverNames[0] // empty' <<<"$obj")"
  public="$(jq -r '.streamSettings.realitySettings.settings.publicKey // .streamSettings.realitySettings.settings.password // empty' <<<"$obj")"
  sid="$(jq -r '.streamSettings.realitySettings.shortIds[0] // empty' <<<"$obj")"
  [ -n "$domain" ] && [ -n "$public" ] && [ -n "$sid" ] || {
    echo "WARNING: cannot generate client links from this inbound; missing domain/publicKey/shortId."
    return 0
  }
  jq -r '.settings.clients[]? | select((.enable // true)==true) | [.id,.email] | @tsv' <<<"$obj" |
  while IFS=$'\t' read -r uuid email; do
    [ -n "$uuid" ] || continue
    local label link
    label="${label_prefix}-${email:-client}"
    link="vless://${uuid}@${PUBLIC_IP}:${port}?type=tcp&security=reality&pbk=$(uri "$public")&fp=chrome&sni=$(uri "$domain")&sid=$(uri "$sid")&spx=%2F&flow=xtls-rprx-vision#$(uri "$label")"
    echo "$link"
  done
}

prepare() {
  [ -n "$DOMAIN" ] || { echo "usage: $0 prepare DOMAIN PUBLIC_IP [TEST_PORT]"; exit 1; }
  local orig shadow payload resp sid test_uuid test_sub test_email future
  orig="$(by_port 443)"
  [ -n "$orig" ] || { echo "ERROR: no production inbound on 443."; exit 1; }

  [ "$(jq -r '.protocol // empty' <<<"$orig")" = "vless" ] || { echo "ERROR: 443 is not VLESS."; exit 1; }
  [ "$(jq -r '.streamSettings.security // empty' <<<"$orig")" = "reality" ] || { echo "ERROR: 443 is not REALITY."; exit 1; }

  local target
  target="$(jq -r '.streamSettings.realitySettings.target // .streamSettings.realitySettings.dest // empty' <<<"$orig")"
  if [ "$target" = "127.0.0.1:8443" ] && \
     [ "$(jq -r '.streamSettings.realitySettings.serverNames[0] // empty' <<<"$orig")" = "$DOMAIN" ]; then
    if [ "$(jq -r '.shareAddrStrategy // empty' <<<"$orig")" != "custom" ] || \
       [ "$(jq -r '.shareAddr // empty' <<<"$orig")" != "$PUBLIC_IP" ]; then
      bash "$ROOT/linux/04a-reality-api.sh" normalize-share "$PUBLIC_IP"
      echo "SUBSCRIPTION_SHARE_ADDRESS_REPAIRED"
    fi
    echo "ALREADY_OPTIMAL"
    exit 0
  fi

  shadow="$(by_port "$TEST_PORT")"
  [ -z "$shadow" ] || { echo "ERROR: test port $TEST_PORT already exists."; exit 1; }

  # Do NOT duplicate production clients into the shadow inbound. Current 3x-ui's
  # own clone UI clears clients, and duplicate identities/stat rows add needless
  # risk. The shadow gets one fresh temporary client while reusing the exact
  # production REALITY server keys/transport that will later be committed.
  test_uuid="$(xui_new_uuid)"
  [ -n "$test_uuid" ] || { echo "ERROR: could not generate shadow UUID."; exit 1; }
  test_sub="$(openssl rand -hex 16)"
  test_email="shadow-$(date +%Y%m%d%H%M%S)"

  payload="$(jq -c \
    --arg domain "$DOMAIN" --arg ip "$PUBLIC_IP" --argjson port "$TEST_PORT" \
    --arg uuid "$test_uuid" --arg sub "$test_sub" --arg email "$test_email" '
    {
      enable,remark,listen,protocol,expiryTime,total,settings,streamSettings,sniffing,
      subSortIndex,trafficReset,trafficResetDay,shareAddrStrategy,shareAddr
    }
    | .port=$port
    | .remark=("reality-opt-shadow-"+($port|tostring))
    | .shareAddrStrategy="custom"
    | .shareAddr=$ip
    | .settings.clients=[{
        id:$uuid,email:$email,flow:"xtls-rprx-vision",limitIp:0,totalGB:0,
        expiryTime:0,enable:true,tgId:0,subId:$sub,comment:"temporary shadow client"
      }]
    | .streamSettings.realitySettings.target="127.0.0.1:8443"
    | del(.streamSettings.realitySettings.dest)
    | .streamSettings.realitySettings.serverNames=[$domain]
  ' <<<"$orig")"

  resp="$(xui_api_post_json "/panel/api/inbounds/add" "$payload")"
  jq -e '.success == true' <<<"$resp" >/dev/null || {
    echo "ERROR creating shadow:"; jq '{success,msg}' <<<"$resp"; exit 1;
  }
  sid="$(jq -r '.obj.id // empty' <<<"$resp")"
  shadow="$(by_port "$TEST_PORT")"

  install -d -m 700 /root/.config/proxy-runbook
  jq -nc \
    --argjson originalId "$(jq -r '.id' <<<"$orig")" \
    --argjson shadowId "${sid:-0}" \
    --arg domain "$DOMAIN" --arg ip "$PUBLIC_IP" --argjson port "$TEST_PORT" \
    '{originalId:$originalId,shadowId:$shadowId,domain:$domain,ip:$ip,testPort:$port,createdAt:(now|todate)}' \
    > /root/.config/proxy-runbook/existing-reality-shadow.json
  chmod 600 /root/.config/proxy-runbook/existing-reality-shadow.json

  if [ -n "${SSH_CONNECTION:-}" ]; then
    SRC="${SSH_CONNECTION%% *}"
    ufw allow from "$SRC" to any port "$TEST_PORT" proto tcp comment 'proxy-runbook-existing-reality-shadow' >/dev/null || true
  fi

  echo "EXISTING_REALITY_SHADOW_READY"
  echo
  echo "=== TEST LINK ON $TEST_PORT (TEMPORARY CLIENT) ==="
  print_links_from_obj "$shadow" "$TEST_PORT" "shadow-test"
  echo

  # Future production links must use the ORIGINAL production clients, not the
  # temporary shadow UUID. Only streamSettings are projected from the tested shadow.
  future="$(jq -c --argjson testedStream "$(jq -c '.streamSettings' <<<"$shadow")" --arg ip "$PUBLIC_IP" \
    '.streamSettings=$testedStream | .shareAddrStrategy="custom" | .shareAddr=$ip' <<<"$orig")"
  echo "=== FUTURE 443 LINKS AFTER COMMIT (ORIGINAL CLIENTS) ==="
  print_links_from_obj "$future" 443 "optimized-443"
  echo
  echo "Test the $TEST_PORT links first. Do NOT commit until they really browse normally."
}

commit() {
  [ -n "$DOMAIN" ] || { echo "usage: $0 commit DOMAIN PUBLIC_IP [TEST_PORT]"; exit 1; }
  local orig shadow oid sid payload resp now target sni share_strategy share_address del
  orig="$(by_port 443)"
  shadow="$(by_port "$TEST_PORT")"
  [ -n "$orig" ] && [ -n "$shadow" ] || { echo "ERROR: original 443 or shadow $TEST_PORT missing."; exit 1; }
  oid="$(jq -r '.id' <<<"$orig")"
  sid="$(jq -r '.id' <<<"$shadow")"

  # Preserve original clients/remark/traffic semantics; copy only the tested optimized streamSettings.
  payload="$(jq -c --argjson testedStream "$(jq -c '.streamSettings' <<<"$shadow")" --arg ip "$PUBLIC_IP" '
    {enable,remark,listen,port,protocol,expiryTime,total,settings,streamSettings,sniffing,
     subSortIndex,trafficReset,trafficResetDay,shareAddrStrategy,shareAddr}
    | .streamSettings=$testedStream
    | .shareAddrStrategy="custom"
    | .shareAddr=$ip
  ' <<<"$orig")"

  resp="$(xui_api_post_json "/panel/api/inbounds/update/${oid}" "$payload")"
  jq -e '.success == true' <<<"$resp" >/dev/null || {
    echo "ERROR updating production 443:"; jq '{success,msg}' <<<"$resp"; exit 1;
  }

  sleep 2
  now="$(by_port 443)"
  target="$(jq -r '.streamSettings.realitySettings.target // empty' <<<"$now")"
  sni="$(jq -r '.streamSettings.realitySettings.serverNames[0] // empty' <<<"$now")"
  share_strategy="$(jq -r '.shareAddrStrategy // empty' <<<"$now")"
  share_address="$(jq -r '.shareAddr // empty' <<<"$now")"
  [ "$target" = "127.0.0.1:8443" ] && [ "$sni" = "$DOMAIN" ] && \
    [ "$share_strategy" = "custom" ] && [ "$share_address" = "$PUBLIC_IP" ] || {
    echo "ERROR: production 443 did not converge; shadow is left in place for recovery."
    exit 1
  }

  del="$(xui_auth_curl -X POST "${XUI_BASE}/panel/api/inbounds/del/${sid}")"
  jq -e '.success == true' <<<"$del" >/dev/null || echo "WARNING: production updated but shadow deletion failed."

  # Remove only rules marked for our shadow.
  mapfile -t N < <(ufw status numbered | grep "$TEST_PORT" | grep 'proxy-runbook-existing-reality-shadow' \
    | sed -n 's/^\[[[:space:]]*\([0-9]\+\)\].*/\1/p' | sort -rn)
  for n in "${N[@]:-}"; do [ -n "$n" ] && yes | ufw delete "$n" >/dev/null || true; done

  rm -f /root/.config/proxy-runbook/existing-reality-shadow.json
  echo "EXISTING_REALITY_443_OPTIMIZED"
  echo
  echo "=== CURRENT 443 CLIENT LINKS ==="
  print_links_from_obj "$now" 443 "optimized-443"
}

abort() {
  local shadow sid
  shadow="$(by_port "$TEST_PORT")"
  if [ -n "$shadow" ]; then
    sid="$(jq -r '.id' <<<"$shadow")"
    xui_auth_curl -X POST \
      "${XUI_BASE}/panel/api/inbounds/del/${sid}" >/dev/null || true
  fi
  mapfile -t N < <(ufw status numbered | grep "$TEST_PORT" | grep 'proxy-runbook-existing-reality-shadow' \
    | sed -n 's/^\[[[:space:]]*\([0-9]\+\)\].*/\1/p' | sort -rn)
  for n in "${N[@]:-}"; do [ -n "$n" ] && yes | ufw delete "$n" >/dev/null || true; done
  rm -f /root/.config/proxy-runbook/existing-reality-shadow.json
  echo "SHADOW_ABORTED"
}

case "$CMD" in
  prepare) prepare ;;
  commit) commit ;;
  abort) abort ;;
  *) echo "usage: $0 {prepare|commit|abort} DOMAIN PUBLIC_IP [TEST_PORT]"; exit 1 ;;
esac
