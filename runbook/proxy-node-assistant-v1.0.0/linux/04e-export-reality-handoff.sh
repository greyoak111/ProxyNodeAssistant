#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/linux/lib-xui-api.sh"
. "$ROOT/linux/lib-handoff.sh"

command -v jq >/dev/null 2>&1 || { echo "jq is required to export Reality handoff." >&2; exit 1; }

PUBLIC_IP="${1:-}"
# A maintenance invocation may run without an argument and without outbound
# DNS/HTTP.  Prefer the already recorded public address before trying the
# external resolver; never manufacture a link with an empty host.
if [ -z "$PUBLIC_IP" ]; then
  for public_file in /etc/proxy-runbook/public.env /etc/text-node-assistant/public.env; do
    if [ -r "$public_file" ]; then
      PUBLIC_IP="$(sed -n -E 's/^((PUBLIC_IP|VPS_PUBLIC_IP|IPV4_PUBLIC)=)//p' "$public_file" | sed -n '1p')"
      [ -n "$PUBLIC_IP" ] && break
    fi
  done
fi
[ -n "$PUBLIC_IP" ] || PUBLIC_IP="$(curl -4fsS --max-time 8 https://api.ipify.org 2>/dev/null || true)"
xui_api_context || { echo "Cannot obtain local 3x-ui API context."; exit 1; }

# Export every enabled VLESS+REALITY inbound, ordered with production 443
# first and then the actual shadow/test ports.  Older revisions only queried
# port 443, which meant an interrupted promotion (for example a live 24443
# or 30443 shadow) lost the only usable client link from the handoff.
INBOUNDS_JSON="$(xui_api_get "/panel/api/inbounds/list")" || {
  echo "Could not read the 3x-ui inbound list; no handoff values were changed." >&2
  exit 1
}
REALITY_OBJS="$(jq -c '[.obj[]? |
  # 3x-ui normally returns numeric ports, but a few older API builds encode
  # them as strings.  Normalize that representation before sorting/export.
  (.settings | if type == "string" then (try fromjson catch {}) else . end) as $settings |
  (.streamSettings | if type == "string" then (try fromjson catch {}) else . end) as $stream |
  .settings = $settings | .streamSettings = $stream |
  (.port | tonumber?) as $port |
  select($port != null and $port >= 1 and $port <= 65535) |
  .port = $port |
  select((.enable // true) == true or (.enable == 1) or (.enable == "1")) |
  select(.protocol == "vless" and .streamSettings.security == "reality")
  ] | sort_by(if .port == 443 then 0 else 1 end, .port)' <<<"$INBOUNDS_JSON")" || {
  echo "The 3x-ui inbound response was not valid JSON; no handoff values were changed." >&2
  exit 1
}
REALITY_COUNT="$(jq -r 'length' <<<"$REALITY_OBJS" 2>/dev/null || echo 0)"
[ "${REALITY_COUNT:-0}" -gt 0 ] || { echo "No enabled VLESS+REALITY inbound was found."; exit 0; }

# The first object is the canonical server profile.  Per-inbound fields are
# exported below as well, so a shadow using a different SNI/key set remains
# recoverable without silently replacing the production profile.
PRIMARY_OBJ="$(jq -c '.[0]' <<<"$REALITY_OBJS")"
PRIMARY_PORT="$(jq -r '.port' <<<"$PRIMARY_OBJ")"
DOMAIN="$(jq -r '.streamSettings.realitySettings.serverNames[0] // empty' <<<"$PRIMARY_OBJ")"
PRIVATE="$(jq -r '.streamSettings.realitySettings.privateKey // empty' <<<"$PRIMARY_OBJ")"
PUBLIC="$(jq -r '.streamSettings.realitySettings.settings.publicKey // .streamSettings.realitySettings.settings.password // empty' <<<"$PRIMARY_OBJ")"
SHORT="$(jq -r '.streamSettings.realitySettings.shortIds[0] // empty' <<<"$PRIMARY_OBJ")"

# 3x-ui's shareAddr is the authoritative advertised address when the caller
# did not provide one (for example a maintenance-menu invocation on a node
# with blocked outbound HTTP).  Keep the fallback local and deterministic.
[ -n "$PUBLIC_IP" ] || PUBLIC_IP="$(jq -r '.shareAddr // empty' <<<"$PRIMARY_OBJ")"

handoff_set "REALITY_SERVER_NAME" "$DOMAIN"
handoff_set "REALITY_SERVER_PORT" "$PRIMARY_PORT"
if [ -n "$PRIVATE" ]; then handoff_set "REALITY_PRIVATE_KEY" "$PRIVATE"; else handoff_delete "REALITY_PRIVATE_KEY"; fi
if [ -n "$PUBLIC" ]; then handoff_set "REALITY_PUBLIC_KEY" "$PUBLIC"; else handoff_delete "REALITY_PUBLIC_KEY"; fi
if [ -n "$SHORT" ]; then handoff_set "REALITY_SHORT_ID" "$SHORT"; else handoff_delete "REALITY_SHORT_ID"; fi

uri(){ jq -rn --arg v "$1" '$v|@uri'; }

echo
echo "================ REAL REALITY SERVER KEYS ==============="
echo "REALITY_SERVER_NAME=$DOMAIN"
echo "REALITY_SERVER_PORT=$PRIMARY_PORT"
echo "REALITY_PRIVATE_KEY=$PRIVATE"
echo "REALITY_PUBLIC_KEY=$PUBLIC"
echo "REALITY_SHORT_ID=$SHORT"
echo "========================================================="
echo
echo "Client identities/links:"
# Remove stale per-client exports left by an older panel configuration before
# writing the current enabled clients.  Only generated Reality fields are
# touched; VPS/panel credentials and links for other protocols remain intact.
for old_i in $(seq 1 128); do
  handoff_delete "REALITY_CLIENT_${old_i}_UUID"
  handoff_delete "REALITY_CLIENT_${old_i}_SUB_ID"
  handoff_delete "REALITY_CLIENT_${old_i}_PORT"
  handoff_delete "REALITY_CLIENT_${old_i}_REMARK"
  handoff_delete "REALITY_CLIENT_${old_i}_LINK"
  handoff_delete "REALITY_CLIENT_${old_i}_SUBSCRIPTION_URL"
done
for old_key in REALITY_PRODUCTION_LINK REALITY_TEST_LINK REALITY_SHADOW_LINK \
  REALITY_TEST_UUID REALITY_TEST_SUB_ID REALITY_TEST_PORT \
  REALITY_GENERATED_UUID REALITY_GENERATED_PRIVATE_KEY REALITY_GENERATED_PUBLIC_KEY \
  REALITY_GENERATED_SHORT_ID REALITY_GENERATED_SUB_ID; do
  handoff_delete "$old_key"
done

# Remove stale per-port material produced by a previous run, but leave
# VLESS_LINK/SUBSCRIPTION_URL untouched: those generic aliases may belong to
# the active CDN/XHTTP route and are refreshed by its own exporter.
while IFS= read -r old_key; do
  [ -n "$old_key" ] || continue
  handoff_delete "$old_key"
done < <(sed -n -E 's/^((REALITY_[0-9]+)_(SERVER_NAME|PRIVATE_KEY|PUBLIC_KEY|SHORT_ID|REMARK))=.*/\1/p' "$HANDOFF_FILE" 2>/dev/null || true)

LINK_HOST="$PUBLIC_IP"
case "$LINK_HOST" in
  *:* ) [[ "$LINK_HOST" = \[*\] ]] || LINK_HOST="[$LINK_HOST]" ;;
esac
i=0
first_test_link=""
while IFS= read -r OBJ; do
  [ -n "$OBJ" ] || continue
  PORT="$(jq -r '.port' <<<"$OBJ")"
  REMARK="$(jq -r '.remark // empty' <<<"$OBJ")"
  OBJ_DOMAIN="$(jq -r '.streamSettings.realitySettings.serverNames[0] // empty' <<<"$OBJ")"
  OBJ_PRIVATE="$(jq -r '.streamSettings.realitySettings.privateKey // empty' <<<"$OBJ")"
  OBJ_PUBLIC="$(jq -r '.streamSettings.realitySettings.settings.publicKey // .streamSettings.realitySettings.settings.password // empty' <<<"$OBJ")"
  OBJ_SHORT="$(jq -r '.streamSettings.realitySettings.shortIds[0] // empty' <<<"$OBJ")"
  [ -n "$OBJ_DOMAIN" ] && [ -n "$OBJ_PUBLIC" ] && [ -n "$OBJ_SHORT" ] || {
    echo "WARNING: skipping Reality inbound ${PORT}; missing serverName/publicKey/shortId." >&2
    continue
  }

  # Preserve per-inbound server material under a deterministic, non-secret
  # port namespace.  The primary values above remain the compatibility alias.
  handoff_set "REALITY_${PORT}_SERVER_NAME" "$OBJ_DOMAIN"
  [ -z "$OBJ_PRIVATE" ] || handoff_set "REALITY_${PORT}_PRIVATE_KEY" "$OBJ_PRIVATE"
  handoff_set "REALITY_${PORT}_PUBLIC_KEY" "$OBJ_PUBLIC"
  handoff_set "REALITY_${PORT}_SHORT_ID" "$OBJ_SHORT"
  [ -z "$REMARK" ] || handoff_set "REALITY_${PORT}_REMARK" "$REMARK"

  if [ -z "$LINK_HOST" ]; then
    echo "WARNING: skipping client links for Reality inbound ${PORT}; no public address is known." >&2
    continue
  fi

  while IFS=$'\t' read -r UUID EMAIL SUBID; do
    [ -n "$UUID" ] || continue
    if ! [[ "$UUID" =~ ^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[1-5][0-9A-Fa-f]{3}-[89ABab][0-9A-Fa-f]{3}-[0-9A-Fa-f]{12}$ ]]; then
      echo "WARNING: skipping malformed Reality client on port ${PORT}." >&2
      continue
    fi
    i=$((i+1))
    LABEL="${EMAIL:-client-$i}"
    LINK="vless://${UUID}@${LINK_HOST}:${PORT}?type=tcp&security=reality&pbk=$(uri "$OBJ_PUBLIC")&fp=chrome&sni=$(uri "$OBJ_DOMAIN")&sid=$(uri "$OBJ_SHORT")&spx=%2F&flow=xtls-rprx-vision#$(uri "$LABEL")"
    handoff_set "REALITY_CLIENT_${i}_UUID" "$UUID"
    handoff_set "REALITY_CLIENT_${i}_SUB_ID" "$SUBID"
    handoff_set "REALITY_CLIENT_${i}_PORT" "$PORT"
    [ -z "$REMARK" ] || handoff_set "REALITY_CLIENT_${i}_REMARK" "$REMARK"
    handoff_set "REALITY_CLIENT_${i}_LINK" "$LINK"
    if [ "$PORT" = "443" ]; then
      handoff_set "REALITY_PRODUCTION_LINK" "$LINK"
    elif [ -z "$first_test_link" ]; then
      first_test_link="$LINK"
      handoff_set "REALITY_TEST_LINK" "$LINK"
      handoff_set "REALITY_SHADOW_LINK" "$LINK"
    fi
    echo "REALITY_CLIENT_${i}_UUID=$UUID"
    echo "REALITY_CLIENT_${i}_SUB_ID=$SUBID"
    echo "REALITY_CLIENT_${i}_PORT=$PORT"
    echo "REALITY_CLIENT_${i}_LINK=$LINK"
    if [[ "$SUBID" =~ ^[A-Za-z0-9._~-]+$ ]] && [ -n "$OBJ_DOMAIN" ]; then
      SUBSCRIPTION_URL="https://${OBJ_DOMAIN}/sub/${SUBID}"
      handoff_set "REALITY_CLIENT_${i}_SUBSCRIPTION_URL" "$SUBSCRIPTION_URL"
      echo "REALITY_CLIENT_${i}_SUBSCRIPTION_URL=$SUBSCRIPTION_URL"
    fi
  done < <(jq -r '.settings.clients[]? |
    select((.enable // true) == true or (.enable == 1) or (.enable == "1")) |
    [.id,.email,(.subId // .sub_id // "")] | @tsv' <<<"$OBJ")
done < <(jq -c '.[]' <<<"$REALITY_OBJS")

echo
echo "REALITY PrivateKey is intentionally shown because this is the explicit credential-handoff screen."
echo "Never put it in a client configuration or share it publicly."
