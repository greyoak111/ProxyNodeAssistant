#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

DOMAIN="${1:-}"
IP="${2:-}"

[ "$(id -u)" -eq 0 ] || { echo "Run as root."; exit 1; }
command -v curl >/dev/null || { echo "curl missing."; exit 1; }
command -v jq >/dev/null || { echo "jq missing."; exit 1; }

[ -n "$DOMAIN" ] || { echo "DOMAIN argument required. This helper never invents a domain."; exit 1; }
[ -n "$IP" ] || { echo "IP argument required."; exit 1; }

read -r -s -p "Cloudflare DNS-Write API Token for THIS run only: " TOKEN
echo
[ -n "$TOKEN" ] || { echo "No token."; exit 1; }

cf_curl() {
  curl -fsS -H @/dev/fd/3 -H "Content-Type: application/json" "$@" \
    3<<<"Authorization: Bearer ${TOKEN}"
}

# Discover the accessible zone by trying suffixes of the exact domain supplied by the user.
IFS='.' read -r -a PARTS <<<"$DOMAIN"
ZONE_ID=""
ZONE_NAME=""
for ((i=0; i<${#PARTS[@]}-1; i++)); do
  candidate="$(IFS=.; echo "${PARTS[*]:i}")"
  R="$(cf_curl -G --data-urlencode "name=${candidate}" \
      "https://api.cloudflare.com/client/v4/zones" || true)"
  zid="$(jq -r '.result[0].id // empty' <<<"$R" 2>/dev/null || true)"
  zname="$(jq -r '.result[0].name // empty' <<<"$R" 2>/dev/null || true)"
  if [ -n "$zid" ] && [ "$zname" = "$candidate" ]; then
    ZONE_ID="$zid"
    ZONE_NAME="$zname"
    break
  fi
done

[ -n "$ZONE_ID" ] || {
  TOKEN=""; unset TOKEN
  echo "No accessible Cloudflare zone matched the domain you typed."
  echo "Use manual DNS instead."
  exit 1
}

echo "Cloudflare zone discovered: $ZONE_NAME"

RR="$(cf_curl -G --data-urlencode "type=A" --data-urlencode "name=${DOMAIN}" \
  "https://api.cloudflare.com/client/v4/zones/${ZONE_ID}/dns_records")"
RID="$(jq -r '.result[0].id // empty' <<<"$RR")"

BODY="$(jq -nc --arg name "$DOMAIN" --arg content "$IP" \
  '{type:"A",name:$name,content:$content,ttl:1,proxied:false,comment:"text-node-assistant node - DNS only"}')"

if [ -n "$RID" ]; then
  RES="$(cf_curl -X PATCH \
    "https://api.cloudflare.com/client/v4/zones/${ZONE_ID}/dns_records/${RID}" \
    --data "$BODY")"
  ACTION="updated"
else
  RES="$(cf_curl -X POST \
    "https://api.cloudflare.com/client/v4/zones/${ZONE_ID}/dns_records" \
    --data "$BODY")"
  ACTION="created"
fi

jq -e '.success == true' <<<"$RES" >/dev/null || {
  echo "Cloudflare DNS API failed:"
  jq '{success,errors,messages}' <<<"$RES"
  TOKEN=""; unset TOKEN
  exit 1
}

TOKEN=""
unset TOKEN
echo "CF_DNS_OK action=${ACTION} name=${DOMAIN} content=${IP} proxied=false"
