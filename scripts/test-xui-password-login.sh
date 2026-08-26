#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT
mkdir -p "$TMP/bin"

cat > "$TMP/bin/fake-xui" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
case "$*" in
  'setting -show')
    printf 'port: 27654\nwebBasePath: /test-path/\n'
    ;;
  *) exit 2 ;;
esac
EOF

cat > "$TMP/bin/curl" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
out='' url='' csrf=0 requested=0 content_type=0 cookie_in=0 cookie_out=0
for arg in "$@"; do
  case "$arg" in
    *test-user*|*test-pass*) echo 'credentials leaked into curl argv' >&2; exit 91 ;;
  esac
done
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) out="$2"; shift 2 ;;
    -c) cookie_out=1; shift 2 ;;
    -b) cookie_in=1; shift 2 ;;
    -H)
      case "$2" in
        'X-Requested-With: XMLHttpRequest') requested=1 ;;
        'X-CSRF-Token: csrf-test') csrf=1 ;;
        'Content-Type: application/x-www-form-urlencoded; charset=UTF-8') content_type=1 ;;
      esac
      shift 2
      ;;
    -w|--max-time) shift 2 ;;
    --data-binary) shift 2 ;;
    -sS) shift ;;
    http://*) url="$1"; shift ;;
    *) shift ;;
  esac
done
[ -n "$out" ] && [ "$requested" -eq 1 ] && [ "$cookie_in" -eq 1 ] && [ "$cookie_out" -eq 1 ]
case "$url" in
  */csrf-token)
    printf '{"success":true,"obj":"csrf-test"}\n' > "$out"
    printf 'csrf\n' >> "$TNA_LOGIN_MARKER"
    printf '200'
    ;;
  */login)
    [ "$csrf" -eq 1 ] && [ "$content_type" -eq 1 ]
    body="$(cat)"
    [ "$body" = 'username=test-user&password=test-pass&twoFactorCode=' ]
    printf '{"success":true,"msg":"ok"}\n' > "$out"
    printf 'login\n' >> "$TNA_LOGIN_MARKER"
    printf '200'
    ;;
  *) exit 92 ;;
esac
EOF

cat > "$TMP/bin/jq" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
query=''
file="${!#}"
for arg in "$@"; do
  case "$arg" in
    -* ) ;;
    * ) if [ -z "$query" ]; then query="$arg"; fi ;;
  esac
done
case "$query" in
  *'.obj | type'*)
    grep -q '"success":true' "$file" && grep -q '"obj":"csrf-test"' "$file"
    printf 'csrf-test\n'
    ;;
  *'.success == true'*)
    grep -q '"success":true' "$file"
    ;;
  *) exit 93 ;;
esac
EOF

cat > "$TMP/bin/python3" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
IFS= read -r username
password="$(cat)"
[ "$username" = test-user ] && [ "$password" = test-pass ]
printf 'username=test-user&password=test-pass&twoFactorCode='
EOF

chmod 700 "$TMP/bin/fake-xui" "$TMP/bin/curl" "$TMP/bin/jq" "$TMP/bin/python3"
export PATH="$TMP/bin:$PATH"
export TNA_XUI_BIN="$TMP/bin/fake-xui"
export TNA_XUI_PUBLIC_FILE="$TMP/public.env"
export TNA_LOGIN_MARKER="$TMP/login.calls"

# shellcheck source=../runbook/text-node-assistant-v0.9.5/linux/lib-xui-api.sh
. "$ROOT/runbook/text-node-assistant-v0.9.5/linux/lib-xui-api.sh"

xui_password_login_works test-user test-pass
[ "$(sed -n '1p' "$TNA_LOGIN_MARKER")" = csrf ]
[ "$(sed -n '2p' "$TNA_LOGIN_MARKER")" = login ]
[ "$(wc -l < "$TNA_LOGIN_MARKER")" -eq 2 ]

echo XUI_PASSWORD_LOGIN_TEST_OK
