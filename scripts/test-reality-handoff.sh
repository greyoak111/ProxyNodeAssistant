#!/usr/bin/env bash
set -Eeuo pipefail

# Fixture test for the read-only Reality exporter.  It uses a fake x-ui/curl
# pair, so it never contacts a VPS or writes outside a temporary directory.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/runbook/proxy-node-assistant-v1.0.0/linux/04e-export-reality-handoff.sh"
command -v jq >/dev/null 2>&1 || { echo REALITY_HANDOFF_TEST_SKIPPED_JQ_MISSING; exit 0; }
TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/state"

cat > "$TMP/bin/fake-xui" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  'setting -show') printf 'port: 2053\nwebBasePath: /panel/\n' ;;
  *) exit 2 ;;
esac
EOF

cat > "$TMP/bin/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
url="${!#}"
case "$url" in
  */panel/api/xray/)
    exit 0
    ;;
  */panel/api/inbounds/list)
    cat "$PNA_REALITY_FIXTURE"
    ;;
  *)
    echo "unexpected fake curl URL: $url" >&2
    exit 22
    ;;
esac
EOF
chmod 700 "$TMP/bin/fake-xui" "$TMP/bin/curl"

cat > "$TMP/fixture.json" <<'EOF'
{
  "obj": [
    {
      "enable": true,
      "remark": "shadow-30443",
      "port": "30443",
      "protocol": "vless",
      "streamSettings": {
        "security": "reality",
        "realitySettings": {
          "serverNames": ["shadow.example.com"],
          "privateKey": "private-30443",
          "settings": {"publicKey": "public-30443"},
          "shortIds": ["3044300000000000"]
        }
      },
      "settings": {"clients": [
        {"enable": true, "id": "11111111-1111-4111-8111-111111111111", "email": "shadow", "subId": "sub30443"}
      ]}
    },
    {
      "enable": true,
      "remark": "production-443",
      "port": 443,
      "protocol": "vless",
      "streamSettings": {
        "security": "reality",
        "realitySettings": {
          "serverNames": ["prod.example.com"],
          "privateKey": "private-443",
          "settings": {"publicKey": "public-443"},
          "shortIds": ["4430000000000000"]
        }
      },
      "settings": {"clients": [
        {"enable": true, "id": "22222222-2222-4222-8222-222222222222", "email": "production", "subId": "sub443"}
      ]}
    },
    {"enable": false, "port": 9443, "protocol": "vless", "streamSettings": {"security": "reality"}},
    {"enable": true, "port": 9444, "protocol": "vless", "streamSettings": {"security": "none"}}
  ]
}
EOF

export PATH="$TMP/bin:$PATH"
export PNA_XUI_BIN="$TMP/bin/fake-xui"
export PNA_XUI_PUBLIC_FILE="$TMP/state/public.env"
export PNA_XUI_INSTALL_RESULT_FILE="$TMP/state/install-result.env"
export PNA_XUI_HANDOFF_FILE="$TMP/state/HANDOFF-SECRETS.txt"
export PNA_XUI_TOKEN_CACHE_FILE="$TMP/state/XUI_API_TOKEN"
export PNA_XUI_GENERATE_MARKER="$TMP/state/generated.calls"
export PNA_REALITY_FIXTURE="$TMP/fixture.json"
export PNA_HANDOFF_DIR="$TMP/state"
export PNA_LEGACY_HANDOFF_DIR="$TMP/legacy"
mkdir -p "$PNA_LEGACY_HANDOFF_DIR"

cat > "$PNA_HANDOFF_DIR/HANDOFF-SECRETS.txt" <<'EOF'
HANDOFF_RUN_STARTED=fixture
VLESS_LINK=vless://existing@example.invalid:443
SUBSCRIPTION_URL=https://existing.example/sub/existing
REALITY_999_PRIVATE_KEY=stale-private
EOF
printf 'fixture-token\n' > "$PNA_HANDOFF_DIR/XUI_API_TOKEN"
export PNA_ACCEPT_TOKENS=fixture-token

output="$($SCRIPT 203.0.113.77 2>&1)"
handoff="$PNA_HANDOFF_DIR/HANDOFF-SECRETS.txt"
grep -Fq 'REALITY_SERVER_PORT=443' "$handoff"
grep -Fq 'REALITY_443_PUBLIC_KEY=public-443' "$handoff"
grep -Fq 'REALITY_30443_PUBLIC_KEY=public-30443' "$handoff"
grep -Fq 'REALITY_CLIENT_1_PORT=443' "$handoff"
grep -Fq 'REALITY_CLIENT_2_PORT=30443' "$handoff"
grep -Fq ':443?' "$handoff"
grep -Fq ':30443?' "$handoff"
grep -Fq 'VLESS_LINK=vless://existing@example.invalid:443' "$handoff"
grep -Fq 'SUBSCRIPTION_URL=https://existing.example/sub/existing' "$handoff"
! grep -Fq 'REALITY_999_PRIVATE_KEY=' "$handoff"
grep -Fq 'REALITY_CLIENT_1_SUBSCRIPTION_URL=https://prod.example.com/sub/sub443' "$handoff"
grep -Fq 'REALITY_CLIENT_2_SUBSCRIPTION_URL=https://shadow.example.com/sub/sub30443' "$handoff"
# The explicit exporter output is useful to an operator, but this test keeps
# the captured fixture output out of the test result and only checks markers.
[ -n "$output" ]
echo REALITY_HANDOFF_TEST_OK
