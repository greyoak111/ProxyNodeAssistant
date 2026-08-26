#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/linux/lib-xui-api.sh"

WARP_PORT="${1:-40000}"
xui_api_context || { echo "ERROR: cannot obtain 3x-ui API context."; exit 1; }
command -v jq >/dev/null || { echo "jq missing."; exit 1; }

R="$(xui_auth_curl -X POST "${XUI_BASE}/panel/api/xray/")"
jq -e '.success == true' <<<"$R" >/dev/null || { echo "Cannot fetch Xray template."; exit 1; }

OUTER="$(jq -r '.obj' <<<"$R")"
CFG="$(jq -c '.xraySetting' <<<"$OUTER")"
TEST_URL="$(jq -r '.outboundTestUrl // "https://www.google.com/generate_204"' <<<"$OUTER")"

# A matching managed outbound and rule are a successful no-op. This check is
# deliberately before backup/test/update so a repeated convergence run does
# not create another backup or restart Xray.
if jq -e --argjson port "$WARP_PORT" '
  ([.outbounds[]? | select(.tag == "warp-masque")] | length) == 1
  and any(.outbounds[]?;
    .tag == "warp-masque"
    and .protocol == "socks"
    and .settings.address == "127.0.0.1"
    and (.settings.port == $port))
  and ([.routing.rules[]? | select(.ruleTag == "openai-via-warp")] | length) == 1
  and any(.routing.rules[]?;
    .ruleTag == "openai-via-warp"
    and .outboundTag == "warp-masque"
    and (([
      "geosite:openai",
      "domain:chatgpt.com",
      "domain:openai.com",
      "domain:oaistatic.com",
      "domain:oaiusercontent.com"
    ] - (.domain // [])) | length) == 0)
' <<<"$CFG" >/dev/null; then
  echo "XRAY_WARP_ROUTE_ALREADY_OPTIMAL"
  exit 0
fi

install -d -m 700 /root/.config/text-node-assistant
STAMP="$(date +%Y%m%d-%H%M%S)"
printf '%s\n' "$OUTER" > "/root/.config/text-node-assistant/xray-template-before-warp-${STAMP}.json"
chmod 600 "/root/.config/text-node-assistant/xray-template-before-warp-${STAMP}.json"

NEWCFG="$(jq -c --argjson port "$WARP_PORT" '
  .outbounds = ((.outbounds // []) | map(select(.tag != "warp-masque"))) +
    [{tag:"warp-masque",protocol:"socks",settings:{address:"127.0.0.1",port:$port}}]
  | .routing = (.routing // {domainStrategy:"AsIs",rules:[]})
  | .routing.rules = ((.routing.rules // []) | map(select(.ruleTag != "openai-via-warp")))
  | .routing.rules = ([{
      type:"field",ruleTag:"openai-via-warp",
      domain:["geosite:openai","domain:chatgpt.com","domain:openai.com","domain:oaistatic.com","domain:oaiusercontent.com"],
      outboundTag:"warp-masque"
    }] + .routing.rules)
' <<<"$CFG")"

# Test the exact outbound before save.
WARP_OUT="$(jq -c --argjson port "$WARP_PORT" '[{tag:"warp-masque",protocol:"socks",settings:{address:"127.0.0.1",port:$port}}]' <<< '{}')"
ALL_OUT="$(jq -c '.outbounds' <<<"$NEWCFG")"
T="$(xui_auth_curl -X POST \
  --data-urlencode "outbounds=${WARP_OUT}" \
  --data-urlencode "allOutbounds=${ALL_OUT}" \
  --data-urlencode "mode=http" \
  "${XUI_BASE}/panel/api/xray/testOutbounds" || true)"

if ! jq -e '.success == true' <<<"$T" >/dev/null 2>&1; then
  echo "ERROR: 3x-ui outbound test did not pass; template was NOT changed."
  printf '%s\n' "$T" | jq . 2>/dev/null || printf '%s\n' "$T"
  exit 1
fi

S="$(xui_auth_curl -X POST \
  --data-urlencode "xraySetting=${NEWCFG}" \
  --data-urlencode "outboundTestUrl=${TEST_URL}" \
  "${XUI_BASE}/panel/api/xray/update")"
jq -e '.success == true' <<<"$S" >/dev/null || {
  echo "ERROR saving Xray template:"; jq '{success,msg}' <<<"$S"; exit 1;
}

RR="$(xui_auth_curl -X POST \
  "${XUI_BASE}/panel/api/server/restartXrayService" || true)"
echo "XRAY_WARP_ROUTE_SAVED"
echo "Backup: /root/.config/text-node-assistant/xray-template-before-warp-${STAMP}.json"
sleep 3
