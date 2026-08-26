#!/usr/bin/env bash
set -Eeuo pipefail
umask 022

DOMAIN="${1:-}"
LANG="${2:-auto}"
SELECTOR="${3:-auto}"
ROOT="/var/www/cover"
TOOLKIT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEMPLATE_ROOT="$TOOLKIT_ROOT/templates/cover-sites"
MANIFEST="$TEMPLATE_ROOT/MANIFEST.tsv"
MARKER="text-node-assistant-cover-library-v2"
TOTAL=15

list_templates() {
  printf 'COVER_TEMPLATE_LIBRARY_V2 count=%s\n' "$TOTAL"
  printf 'ID\tSLUG\tTITLE\n'
  awk -F '\t' '{printf "%s\t%s\t%s\n", $1, $2, $3}' "$MANIFEST"
}

if [ "$DOMAIN" = "--list" ] || [ "${SELECTOR,,}" = "list" ]; then
  [ -s "$MANIFEST" ] || { echo "Cover template manifest is missing." >&2; exit 3; }
  list_templates
  exit 0
fi

[ "$(id -u)" -eq 0 ] || { echo "Run as root."; exit 1; }
[ -n "$DOMAIN" ] || { echo "DOMAIN is required."; exit 1; }
[ -s "$MANIFEST" ] || { echo "Cover template manifest is missing."; exit 3; }

case "$LANG" in
  zh|en|auto) ;;
  *) LANG=auto ;;
esac

choose_template_id() {
  local choice="${SELECTOR,,}" hex seed current
  case "$choice" in
    ""|r|random)
      seed="$(od -An -N4 -tu4 /dev/urandom 2>/dev/null | tr -d ' ' || true)"
      [ -n "$seed" ] || seed="$(date +%s%N 2>/dev/null || date +%s)"
      TEMPLATE_ID=$((seed % TOTAL + 1))
      current="$(sed -n 's/^template_id=//p' "$ROOT/.text-node-assistant-cover" 2>/dev/null | head -n 1 || true)"
      if [[ "$current" =~ ^[0-9]+$ ]] && [ "$current" -eq "$TEMPLATE_ID" ] && [ "$TOTAL" -gt 1 ]; then
        TEMPLATE_ID=$((TEMPLATE_ID % TOTAL + 1))
      fi
      TEMPLATE_MODE="random"
      ;;
    a|auto|stable)
      hex="$(printf '%s' "$DOMAIN" | sha256sum | cut -c1-8)"
      TEMPLATE_ID=$((16#$hex % TOTAL + 1))
      TEMPLATE_MODE="auto"
      ;;
    *)
      if ! [[ "$choice" =~ ^[0-9]{1,2}$ ]]; then
        echo "Invalid cover template selector: $SELECTOR" >&2
        list_templates >&2
        exit 2
      fi
      TEMPLATE_ID=$((10#$choice))
      if [ "$TEMPLATE_ID" -lt 1 ] || [ "$TEMPLATE_ID" -gt "$TOTAL" ]; then
        echo "Cover template number must be between 1 and $TOTAL." >&2
        list_templates >&2
        exit 2
      fi
      TEMPLATE_MODE="specified"
      ;;
  esac
}

choose_template_id
ENTRY="$(awk -F '\t' -v id="$TEMPLATE_ID" '$1 == id {print $2 "\t" $3 "\t" $4; exit}' "$MANIFEST")"
[ -n "$ENTRY" ] || { echo "Template $TEMPLATE_ID is missing from the manifest." >&2; exit 3; }
IFS=$'\t' read -r TEMPLATE_SLUG TEMPLATE_TITLE TEMPLATE_FILE <<<"$ENTRY"
SOURCE="$TEMPLATE_ROOT/$TEMPLATE_FILE"
[ -s "$SOURCE" ] || { echo "Template file is missing: $SOURCE" >&2; exit 3; }

if [ -d "$ROOT" ] && [ -f "$ROOT/index.html" ] && [ ! -f "$ROOT/.text-node-assistant-cover" ] && ! grep -q "$MARKER" "$ROOT/index.html"; then
  if grep -qE 'This site is online|<h1>Welcome</h1>' "$ROOT/index.html"; then
    echo "Detected a placeholder cover page; safe to upgrade."
  else
    echo "EXISTING_CUSTOM_COVER=YES"
    echo "A non-runbook/custom site exists at $ROOT."
    if [ "${REPLACE_COVER:-0}" != "1" ]; then
      echo "Refusing to overwrite it without explicit REPLACE_COVER=1."
      exit 20
    fi
    echo "Explicit replacement approved; the current site will be backed up first."
  fi
fi

STAMP="$(date +%Y%m%d-%H%M%S)"
if [ -d "$ROOT" ]; then
  cp -a "$ROOT" "/root/cover-site-before-${STAMP}" 2>/dev/null || true
fi

# Remove only the managed public artwork.  ACME challenge state is deliberately
# outside this list and remains available throughout a template switch.
install -d -m 755 "$ROOT" "$ROOT/assets" "$ROOT/.well-known" "$ROOT/.well-known/acme-challenge"
rm -rf "$ROOT/about" "$ROOT/status"
rm -f "$ROOT/index.html" "$ROOT/404.html" "$ROOT/robots.txt" "$ROOT/assets/favicon.svg"

TMP_INDEX="$(mktemp "$ROOT/.index.XXXXXX")"
install -m 644 "$SOURCE" "$TMP_INDEX"
sed -i \
  -e "s|{{DOMAIN}}|$DOMAIN|g" \
  -e "s|{{YEAR}}|$(date -u +%Y)|g" \
  -e "s|{{UPDATED}}|$(date -u +%Y-%m-%d)|g" \
  "$TMP_INDEX"

grep -q "$MARKER" "$TMP_INDEX" || { rm -f "$TMP_INDEX"; echo "Template marker validation failed." >&2; exit 4; }
if grep -qE '\{\{(DOMAIN|YEAR|UPDATED)\}\}' "$TMP_INDEX"; then
  rm -f "$TMP_INDEX"
  echo "Template placeholder replacement failed." >&2
  exit 4
fi
mv -f "$TMP_INDEX" "$ROOT/index.html"
chmod 644 "$ROOT/index.html"

ACCENT_HEX="$(printf '%s' "$DOMAIN:$TEMPLATE_ID" | sha256sum | cut -c1-6)"
cat > "$ROOT/assets/favicon.svg" <<EOF
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64">
  <rect x="5" y="5" width="54" height="54" rx="12" fill="#$ACCENT_HEX"/>
  <path d="M18 42V22h8l12 20h8V22" fill="none" stroke="white" stroke-width="5" stroke-linecap="square"/>
</svg>
EOF

cat > "$ROOT/404.html" <<EOF
<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta name="generator" content="$MARKER"><title>Not found · $TEMPLATE_TITLE</title><style>body{margin:0;min-height:100vh;display:grid;place-items:center;background:#101418;color:#e8edf2;font:16px/1.6 system-ui,sans-serif}.box{width:min(620px,calc(100% - 40px));border:1px solid #3b4650;padding:42px}b{font:64px/1 monospace}a{color:#66e6d2}</style></head><body><main class="box"><b>404</b><h1>That page is not part of this public site.</h1><p>The requested path is unavailable.</p><p><a href="/">Return to $TEMPLATE_TITLE →</a></p></main></body></html>
EOF

cat > "$ROOT/robots.txt" <<'EOF'
User-agent: *
Allow: /
EOF

cat > "$ROOT/.text-node-assistant-cover" <<EOF
marker=$MARKER
domain=$DOMAIN
template_id=$TEMPLATE_ID
template_slug=$TEMPLATE_SLUG
template_title=$TEMPLATE_TITLE
template_mode=$TEMPLATE_MODE
updated=$(date -Is)
EOF
chmod 644 "$ROOT/.text-node-assistant-cover" "$ROOT/404.html" "$ROOT/robots.txt" "$ROOT/assets/favicon.svg"

echo "POLISHED_COVER_OK template=$TEMPLATE_ID slug=$TEMPLATE_SLUG title=$TEMPLATE_TITLE mode=$TEMPLATE_MODE root=$ROOT backup=/root/cover-site-before-${STAMP}"
