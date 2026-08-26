#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/linux/lib-xui-api.sh"

DOMAIN="${1:-}"
SUB_PORT="${2:-2096}"
SUB_PROXY_PORT=2097
[ "$(id -u)" -eq 0 ] || { echo "Run as root."; exit 1; }
[ -n "$DOMAIN" ] || { echo "DOMAIN is required."; exit 1; }
[[ "$SUB_PORT" =~ ^[0-9]+$ ]] && [ "$SUB_PORT" -ge 1 ] && [ "$SUB_PORT" -le 65535 ] || {
  echo "Subscription port is invalid."
  exit 1
}

xui_api_context || { echo "ERROR: cannot obtain local 3x-ui API context."; exit 1; }
command -v jq >/dev/null || { echo "jq missing."; exit 1; }

CURRENT="$(xui_auth_curl -X POST "${XUI_BASE}/panel/api/setting/all")"
jq -e '.success == true and (.obj | type == "object")' <<<"$CURRENT" >/dev/null || {
  echo "ERROR: could not read 3x-ui subscription settings."
  exit 1
}

SUB_URI="https://${DOMAIN}/sub/"
DRIFT="$(jq -r --arg domain "$DOMAIN" --arg uri "$SUB_URI" --argjson port "$SUB_PORT" '
  .obj |
  (.subEnable != true) or
  (.subListen != "127.0.0.1") or
  (.subPort != $port) or
  (.subPath != "/sub/") or
  (.subDomain != $domain) or
  (.subURI != $uri) or
  (.subEncrypt != true)
' <<<"$CURRENT")"

if [ "$DRIFT" = "true" ]; then
  PAYLOAD="$(jq -c --arg domain "$DOMAIN" --arg uri "$SUB_URI" --argjson port "$SUB_PORT" '
    .obj
    | .subEnable=true
    | .subListen="127.0.0.1"
    | .subPort=$port
    | .subPath="/sub/"
    | .subDomain=$domain
    | .subURI=$uri
    | .subEncrypt=true
  ' <<<"$CURRENT")"
  RESPONSE="$(xui_api_post_json "/panel/api/setting/update" "$PAYLOAD")"
  jq -e '.success == true' <<<"$RESPONSE" >/dev/null || {
    echo "ERROR: 3x-ui rejected the subscription settings update."
    jq '{success,msg}' <<<"$RESPONSE"
    exit 1
  }
  systemctl restart x-ui
  for _ in $(seq 1 30); do
    systemctl is-active --quiet x-ui && \
      ss -lntp 2>/dev/null | grep -E "127\\.0\\.0\\.1:${SUB_PORT}[[:space:]]" >/dev/null && break
    sleep 1
  done
  echo "SUBSCRIPTION_SETTINGS_NORMALIZED"
else
  echo "SUBSCRIPTION_SETTINGS_ALREADY_OPTIMAL"
fi

LINE="$(ss -lntp 2>/dev/null | grep -E ":${SUB_PORT}[[:space:]]" || true)"
grep -E "127\\.0\\.0\\.1:${SUB_PORT}[[:space:]]" <<<"$LINE" >/dev/null || {
  echo "ERROR: subscription server is not listening on localhost:${SUB_PORT}."
  exit 1
}
if grep -Eq "0\\.0\\.0\\.0:${SUB_PORT}|\\[::\\]:${SUB_PORT}|\\*:${SUB_PORT}" <<<"$LINE"; then
  echo "ERROR: subscription server is publicly bound."
  exit 1
fi

systemctl is-active --quiet text-node-assistant-subscription-proxy.service || {
  echo "ERROR: local subscription adapter is not active."
  exit 1
}
PROXY_LINE="$(ss -lntp 2>/dev/null | grep -E ":${SUB_PROXY_PORT}[[:space:]]" || true)"
grep -q "127\.0\.0\.1:${SUB_PROXY_PORT}" <<<"$PROXY_LINE" || {
  echo "ERROR: local subscription adapter is not listening on localhost:${SUB_PROXY_PORT}."
  exit 1
}
nginx -T 2>/dev/null | grep -F "proxy_pass http://127.0.0.1:${SUB_PROXY_PORT};" >/dev/null || {
  echo "ERROR: Nginx HTTPS subscription rewrite proxy is missing."
  exit 1
}

STATUS="$(curl -sS --max-time 10 -o /dev/null -w '%{http_code}' \
  -H "Host: ${DOMAIN}" "http://127.0.0.1:${SUB_PROXY_PORT}/sub/text-node-assistant-probe-missing")"
[ "$STATUS" = "404" ] || {
  echo "ERROR: localhost subscription probe returned HTTP ${STATUS}."
  exit 1
}

echo "SUBSCRIPTION_PROXY_OPTIMAL uri=${SUB_URI}<client-sub-id> adapter=localhost:${SUB_PROXY_PORT}"
