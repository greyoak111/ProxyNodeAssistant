#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/linux/lib-xui-api.sh"
. "$ROOT/linux/lib-handoff.sh"

PUBLIC_IP="${1:-$(curl -4fsS --max-time 8 https://api.ipify.org 2>/dev/null || true)}"
xui_api_context || { echo "Cannot obtain local 3x-ui API context."; exit 1; }

OBJ="$(xui_api_get "/panel/api/inbounds/list" | jq -c '.obj[]? | select(.port==443 and .protocol=="vless" and .streamSettings.security=="reality")' | sed -n '1p')"
[ -n "$OBJ" ] || { echo "No VLESS+REALITY inbound on 443."; exit 0; }

DOMAIN="$(jq -r '.streamSettings.realitySettings.serverNames[0] // empty' <<<"$OBJ")"
PRIVATE="$(jq -r '.streamSettings.realitySettings.privateKey // empty' <<<"$OBJ")"
PUBLIC="$(jq -r '.streamSettings.realitySettings.settings.publicKey // .streamSettings.realitySettings.settings.password // empty' <<<"$OBJ")"
SHORT="$(jq -r '.streamSettings.realitySettings.shortIds[0] // empty' <<<"$OBJ")"

handoff_set "REALITY_SERVER_NAME" "$DOMAIN"
handoff_set "REALITY_PRIVATE_KEY" "$PRIVATE"
handoff_set "REALITY_PUBLIC_KEY" "$PUBLIC"
handoff_set "REALITY_SHORT_ID" "$SHORT"

uri(){ jq -rn --arg v "$1" '$v|@uri'; }

echo
echo "================ REAL REALITY SERVER KEYS ==============="
echo "REALITY_SERVER_NAME=$DOMAIN"
echo "REALITY_PRIVATE_KEY=$PRIVATE"
echo "REALITY_PUBLIC_KEY=$PUBLIC"
echo "REALITY_SHORT_ID=$SHORT"
echo "========================================================="
echo
echo "Client identities/links:"
i=0
while IFS=$'\t' read -r UUID EMAIL SUBID; do
  [ -n "$UUID" ] || continue
  i=$((i+1))
  handoff_set "REALITY_CLIENT_${i}_UUID" "$UUID"
  handoff_set "REALITY_CLIENT_${i}_SUB_ID" "$SUBID"
  LINK="vless://${UUID}@${PUBLIC_IP}:443?type=tcp&security=reality&pbk=$(uri "$PUBLIC")&fp=chrome&sni=$(uri "$DOMAIN")&sid=$(uri "$SHORT")&spx=%2F&flow=xtls-rprx-vision#$(uri "${EMAIL:-client-$i}")"
  handoff_set "REALITY_CLIENT_${i}_LINK" "$LINK"
  echo "REALITY_CLIENT_${i}_UUID=$UUID"
  echo "REALITY_CLIENT_${i}_SUB_ID=$SUBID"
  echo "REALITY_CLIENT_${i}_LINK=$LINK"
  if [ -n "$SUBID" ] && [ -n "$DOMAIN" ]; then
    SUBSCRIPTION_URL="https://${DOMAIN}/sub/${SUBID}"
    handoff_set "REALITY_CLIENT_${i}_SUBSCRIPTION_URL" "$SUBSCRIPTION_URL"
    echo "REALITY_CLIENT_${i}_SUBSCRIPTION_URL=$SUBSCRIPTION_URL"
  fi
done < <(jq -r '.settings.clients[]? | select((.enable // true)==true) | [.id,.email,.subId] | @tsv' <<<"$OBJ")

echo
echo "REALITY PrivateKey is intentionally shown because this is the explicit credential-handoff screen."
echo "Never put it in a client configuration or share it publicly."
