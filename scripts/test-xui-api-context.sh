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
  'setting -show')
    printf 'port: 27654\nwebBasePath: /test-path/\n'
    ;;
  'setting -getApiToken')
    printf '1\n' >> "$PNA_XUI_GENERATE_MARKER"
    printf 'A new fallback token has been generated.\napiToken: generated-token\n'
    ;;
  *)
    exit 2
    ;;
esac
EOF

cat > "$TMP/bin/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
header=''
IFS= read -r header <&3 || true
token="${header#Authorization: Bearer }"
case ",${PNA_ACCEPT_TOKENS:-}," in
  *",${token},"*) exit 0 ;;
  *) exit 22 ;;
esac
EOF
cat > "$TMP/bin/install" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
# Git Bash cannot apply Linux mode bits to its synthetic /tmp ACL. The
# production implementation still uses install(1); this test shim preserves
# directory creation semantics while the real Linux path is covered by syntax
# and source-contract tests.
target="${*: -1}"
mkdir -p -- "$target"
EOF
chmod 700 "$TMP/bin/fake-xui" "$TMP/bin/curl" "$TMP/bin/install"

export PATH="$TMP/bin:$PATH"
export PNA_XUI_BIN="$TMP/bin/fake-xui"
export PNA_XUI_PUBLIC_FILE="$TMP/state/public.env"
export PNA_XUI_INSTALL_RESULT_FILE="$TMP/state/install-result.env"
export PNA_XUI_HANDOFF_FILE="$TMP/state/HANDOFF-SECRETS.txt"
export PNA_XUI_TOKEN_CACHE_FILE="$TMP/state/XUI_API_TOKEN"
export PNA_XUI_GENERATE_MARKER="$TMP/state/generated.calls"

# shellcheck source=../runbook/proxy-node-assistant-v1.0.0/linux/lib-xui-api.sh
. "$ROOT/runbook/proxy-node-assistant-v1.0.0/linux/lib-xui-api.sh"

reset_context() {
  unset XUI_API_TOKEN XUI_API_TOKEN_SOURCE XUI_BASE XUI_PORT XUI_WEB_BASE_PATH XUI_BIN
}

# A valid handoff token must be reused without generating another token.
printf 'PANEL_API_TOKEN=handoff-token\n' > "$PNA_XUI_HANDOFF_FILE"
printf 'XUI_API_TOKEN=install-token\n' > "$PNA_XUI_INSTALL_RESULT_FILE"
export PNA_ACCEPT_TOKENS='handoff-token'
reset_context
xui_api_context
[ "$XUI_API_TOKEN" = 'handoff-token' ]
[ "$XUI_API_TOKEN_SOURCE" = 'handoff' ]
[ "$XUI_BASE" = 'http://127.0.0.1:27654/test-path' ]
[ ! -e "$PNA_XUI_GENERATE_MARKER" ]

# If the handoff token is stale, the install-result token is tried next.
rm -f -- "$PNA_XUI_TOKEN_CACHE_FILE"
printf 'PANEL_API_TOKEN=stale-token\n' > "$PNA_XUI_HANDOFF_FILE"
printf 'XUI_API_TOKEN=install-token\n' > "$PNA_XUI_INSTALL_RESULT_FILE"
export PNA_ACCEPT_TOKENS='install-token'
reset_context
xui_api_context
[ "$XUI_API_TOKEN" = 'install-token' ]
[ "$XUI_API_TOKEN_SOURCE" = 'install-result' ]
[ ! -e "$PNA_XUI_GENERATE_MARKER" ]

# Generation is a last resort, is cached, and must happen only once.
rm -f -- "$PNA_XUI_TOKEN_CACHE_FILE"
: > "$PNA_XUI_HANDOFF_FILE"
: > "$PNA_XUI_INSTALL_RESULT_FILE"
export PNA_ACCEPT_TOKENS='generated-token'
reset_context
xui_api_context
[ "$XUI_API_TOKEN" = 'generated-token' ]
[ "$XUI_API_TOKEN_SOURCE" = 'generated' ]
[ "$(cat "$PNA_XUI_TOKEN_CACHE_FILE")" = 'generated-token' ]
[ "$(wc -l < "$PNA_XUI_GENERATE_MARKER")" -eq 1 ]

reset_context
xui_api_context
[ "$XUI_API_TOKEN_SOURCE" = 'cache' ]
[ "$(wc -l < "$PNA_XUI_GENERATE_MARKER")" -eq 1 ]

echo XUI_API_CONTEXT_TEST_OK
