#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/linux/lib-handoff.sh"

find_xray() {
  local p pid
  pid="$(pgrep -f 'xray(-linux-[^ ]*)?$|/xray ' | sed -n '1p' || true)"
  if [ -n "$pid" ]; then
    p="$(readlink -f "/proc/$pid/exe" 2>/dev/null || true)"
    if [ -n "$p" ] && [ -x "$p" ]; then echo "$p"; return 0; fi
  fi
  for p in \
    /usr/local/x-ui/bin/xray-linux-amd64 \
    /usr/local/x-ui/bin/xray-linux-arm64 \
    /usr/local/x-ui/bin/xray \
    /usr/local/bin/xray \
    /usr/bin/xray; do
    if [ -x "$p" ]; then echo "$p"; return 0; fi
  done
  p="$(find /usr/local/x-ui /usr/local/bin /usr/bin -maxdepth 4 -type f -name 'xray*' -perm -111 2>/dev/null | sed -n '1p' || true)"
  [ -n "$p" ] && { echo "$p"; return 0; }
  return 1
}

XRAY="$(find_xray)" || {
  echo "ERROR: Xray executable not found."
  exit 1
}

STAMP="$(date +%Y%m%d-%H%M%S)"
OUT="/root/.config/text-node-assistant/reality-credentials-${STAMP}.txt"
install -d -m 700 /root/.config/text-node-assistant

UUID_RAW="$("$XRAY" uuid 2>&1 | tr -d '\r')"
UUID="$(jq -r 'if type == "object" then (.uuid // empty) elif type == "string" then . else empty end' \
  <<<"$UUID_RAW" 2>/dev/null || true)"
if ! [[ "$UUID" =~ ^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$ ]]; then
  UUID="$(grep -Eo '[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}' <<<"$UUID_RAW" | sed -n '1p' || true)"
fi
[[ "$UUID" =~ ^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$ ]] || {
  echo "ERROR: Xray returned an invalid UUID shape."
  exit 1
}
KEYS="$("$XRAY" x25519 2>&1 | tr -d '\r')"
PRIVATE="$(printf '%s\n' "$KEYS" | sed -nE 's/^(PrivateKey|Private key):[[:space:]]*//p' | sed -n '1p')"
PUBLIC="$(printf '%s\n' "$KEYS" | sed -nE 's/^(Password \(PublicKey\)|Password|PublicKey|Public key):[[:space:]]*//p' | sed -n '1p')"
SID="$(openssl rand -hex 8)"
SUBID="$(openssl rand -hex 16)"

{
  echo "XRAY=$XRAY"
  echo "CREATED=$(date -Is 2>/dev/null || date)"
  echo "UUID=$UUID"
  printf '%s\n' "$KEYS"
  echo "SHORT_ID=$SID"
  echo "SUB_ID=$SUBID"
} > "$OUT"
chmod 600 "$OUT"

handoff_set "REALITY_GENERATED_UUID" "$UUID"
[ -n "$PRIVATE" ] && handoff_set "REALITY_GENERATED_PRIVATE_KEY" "$PRIVATE"
[ -n "$PUBLIC" ] && handoff_set "REALITY_GENERATED_PUBLIC_KEY" "$PUBLIC"
handoff_set "REALITY_GENERATED_SHORT_ID" "$SID"
handoff_set "REALITY_GENERATED_SUB_ID" "$SUBID"

echo
echo "================ REAL GENERATED REALITY CREDENTIALS ================"
echo "UUID=$UUID"
printf '%s\n' "$KEYS"
echo "SHORT_ID=$SID"
echo "SUB_ID=$SUBID"
echo "===================================================================="
echo "Root-only copy: $OUT"
echo "The values are intentionally shown in full for operator handoff."
echo "Do not put the REALITY PrivateKey in a client or public post."
