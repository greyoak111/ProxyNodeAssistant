#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/state"

cat > "$TMP/bin/fake-xui" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "$*" in
  'setting -show') printf 'port: 27654\nwebBasePath: /test-path/\n' ;;
  'setting -getApiToken') echo 'token generation must not run' >&2; exit 90 ;;
  *) exit 2 ;;
esac
EOF

cat > "$TMP/bin/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case " $* " in
  *' -o /dev/null '*) exit 0 ;;
  *'/panel/api/xray/'*) printf '{"success":true}\n' ;;
  *)
    printf '%s\n' "$*" > "$TNA_UNEXPECTED_CURL_MARKER"
    exit 91
    ;;
esac
EOF

# This control-flow test isolates the runbook from host dependencies. The Go
# static regression also asserts the full jq predicate fields, while the live
# verification runs the real jq expression against 3x-ui.
cat > "$TMP/bin/jq" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
filter="$*"
case "$filter" in
  *'.success == true'*) exit 0 ;;
  *'.obj'*) printf 'outer-placeholder\n' ;;
  *'.xraySetting'*) printf '{"outbounds":[],"routing":{"rules":[]}}\n' ;;
  *'.outboundTestUrl'*) printf 'https://www.google.com/generate_204\n' ;;
  *'.outbounds[]?'*'warp-masque'*'openai-via-warp'*) exit 0 ;;
  *) echo "unexpected jq call: $filter" >&2; exit 92 ;;
esac
EOF
chmod 700 "$TMP/bin/fake-xui" "$TMP/bin/curl" "$TMP/bin/jq"

export PATH="$TMP/bin:$PATH"
export TNA_XUI_BIN="$TMP/bin/fake-xui"
export TNA_XUI_PUBLIC_FILE="$TMP/state/public.env"
export TNA_XUI_INSTALL_RESULT_FILE="$TMP/state/install-result.env"
export TNA_XUI_HANDOFF_FILE="$TMP/state/HANDOFF-SECRETS.txt"
export TNA_XUI_TOKEN_CACHE_FILE="$TMP/state/XUI_API_TOKEN"
export TNA_UNEXPECTED_CURL_MARKER="$TMP/state/unexpected-curl"
printf 'PANEL_API_TOKEN=test-token\n' > "$TNA_XUI_HANDOFF_FILE"

output="$(bash "$ROOT/runbook/text-node-assistant-v0.9.5/linux/07a-apply-warp-route-local.sh" 40000)"
[ "$output" = 'XRAY_WARP_ROUTE_ALREADY_OPTIMAL' ]
[ ! -e "$TNA_UNEXPECTED_CURL_MARKER" ]

echo WARP_ROUTE_IDEMPOTENCY_TEST_OK
