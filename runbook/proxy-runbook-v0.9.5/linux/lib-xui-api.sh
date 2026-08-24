#!/usr/bin/env bash

xui_find_bin() {
  if [ -n "${PNA_XUI_BIN:-}" ] && [ -x "$PNA_XUI_BIN" ]; then
    printf '%s\n' "$PNA_XUI_BIN"
  elif [ -x /usr/local/x-ui/x-ui ]; then
    printf '%s\n' /usr/local/x-ui/x-ui
  elif command -v x-ui >/dev/null 2>&1; then
    command -v x-ui
  else
    return 1
  fi
}

xui_env_value() {
  local file="$1" key="$2" line
  [ -r "$file" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      "${key}="*)
        printf '%s\n' "${line#*=}"
        return 0
        ;;
    esac
  done < "$file"
  return 1
}

xui_first_line() {
  local file="$1" value=''
  [ -r "$file" ] || return 1
  IFS= read -r value < "$file" || true
  value="${value%$'\r'}"
  [ -n "$value" ] || return 1
  printf '%s\n' "$value"
}

xui_token_works() {
  local candidate="$1"
  [ -n "$candidate" ] || return 1
  curl -fsS --max-time 10 -o /dev/null \
    -H @/dev/fd/3 \
    -X POST "${XUI_BASE}/panel/api/xray/" \
    3<<<"Authorization: Bearer ${candidate}" 2>/dev/null
}

xui_store_token() {
  local token="$1" cache_file handoff_file cache_dir handoff_dir tmp
  cache_file="${PNA_XUI_TOKEN_CACHE_FILE:-/root/.config/proxy-runbook/XUI_API_TOKEN}"
  handoff_file="${PNA_XUI_HANDOFF_FILE:-/root/.config/proxy-runbook/HANDOFF-SECRETS.txt}"
  cache_dir="$(dirname "$cache_file")"
  handoff_dir="$(dirname "$handoff_file")"
  umask 077
  install -d -m 700 "$cache_dir" "$handoff_dir" || return 1

  tmp="$(mktemp "${cache_dir}/.xui-api-token.XXXXXX")" || return 1
  printf '%s\n' "$token" > "$tmp"
  chmod 600 "$tmp"
  mv -f -- "$tmp" "$cache_file"

  tmp="$(mktemp "${handoff_dir}/.handoff.XXXXXX")" || return 1
  if [ -r "$handoff_file" ]; then
    grep -v '^PANEL_API_TOKEN=' "$handoff_file" > "$tmp" || true
  fi
  printf 'PANEL_API_TOKEN=%s\n' "$token" >> "$tmp"
  chmod 600 "$tmp"
  mv -f -- "$tmp" "$handoff_file"
}

xui_generate_token_once() {
  local xui="$1" output line token=''
  output="$("$xui" setting -getApiToken 2>/dev/null || true)"
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      apiToken:*)
        token="${line#apiToken:}"
        token="${token#${token%%[![:space:]]*}}"
        break
        ;;
    esac
  done <<< "$output"
  [ -n "$token" ] || return 1
  printf '%s\n' "$token"
}

xui_api_context() {
  local xui show port raw_path clean_path public_file install_file handoff_file cache_file
  local token='' source='' generated='' i
  local -a tokens sources

  xui="$(xui_find_bin)" || {
    printf '%s\n' 'ERROR: 3x-ui binary was not found.' >&2
    return 1
  }
  public_file="${PNA_XUI_PUBLIC_FILE:-/etc/proxy-runbook/public.env}"
  install_file="${PNA_XUI_INSTALL_RESULT_FILE:-/etc/x-ui/install-result.env}"
  handoff_file="${PNA_XUI_HANDOFF_FILE:-/root/.config/proxy-runbook/HANDOFF-SECRETS.txt}"
  cache_file="${PNA_XUI_TOKEN_CACHE_FILE:-/root/.config/proxy-runbook/XUI_API_TOKEN}"

  show="$("$xui" setting -show 2>/dev/null || true)"
  port="$(printf '%s\n' "$show" | sed -nE 's/^[[:space:]]*(port|panelPort):[[:space:]]*([0-9]+).*$/\2/p' | sed -n '1p')"
  raw_path="$(printf '%s\n' "$show" | sed -nE 's/^[[:space:]]*(webBasePath|web base path):[[:space:]]*(.*)$/\2/p' | sed -n '1p')"
  [ -n "$port" ] || port="$(xui_env_value "$public_file" PANEL_PORT 2>/dev/null || true)"
  [ -n "$port" ] || port="$(xui_env_value "$install_file" XUI_PANEL_PORT 2>/dev/null || true)"
  [ -n "$raw_path" ] || raw_path="$(xui_env_value "$public_file" WEB_BASE_PATH 2>/dev/null || true)"
  [ -n "$raw_path" ] || raw_path="$(xui_env_value "$install_file" XUI_WEB_BASE_PATH 2>/dev/null || true)"

  case "$port" in
    ''|*[!0-9]*)
      printf '%s\n' 'ERROR: 3x-ui panel port is missing or invalid.' >&2
      return 1
      ;;
  esac
  if [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
    printf '%s\n' 'ERROR: 3x-ui panel port is outside 1..65535.' >&2
    return 1
  fi
  case "$raw_path" in
    *$'\r'*|*$'\n'*|*$'\t'*|*' '*)
      printf '%s\n' 'ERROR: 3x-ui web base path is unsafe.' >&2
      return 1
      ;;
  esac
  [ -n "$raw_path" ] || raw_path='/'
  raw_path="/${raw_path#/}"
  clean_path="${raw_path#/}"
  clean_path="${clean_path%/}"

  XUI_BIN="$xui"
  XUI_PORT="$port"
  XUI_WEB_BASE_PATH="$raw_path"
  if [ -n "$clean_path" ]; then
    XUI_BASE="http://127.0.0.1:${port}/${clean_path}"
  else
    XUI_BASE="http://127.0.0.1:${port}"
  fi

  tokens=(
    "${XUI_API_TOKEN:-}"
    "$(xui_first_line "$cache_file" 2>/dev/null || true)"
    "$(xui_env_value "$handoff_file" PANEL_API_TOKEN 2>/dev/null || true)"
    "$(xui_env_value "$install_file" XUI_API_TOKEN 2>/dev/null || true)"
  )
  sources=(environment cache handoff install-result)
  for i in "${!tokens[@]}"; do
    [ -n "${tokens[$i]}" ] || continue
    if xui_token_works "${tokens[$i]}"; then
      token="${tokens[$i]}"
      source="${sources[$i]}"
      break
    fi
  done

  if [ -z "$token" ]; then
    generated="$(xui_generate_token_once "$xui" || true)"
    if [ -n "$generated" ] && xui_token_works "$generated"; then
      token="$generated"
      source='generated'
    fi
  fi
  if [ -z "$token" ]; then
    printf '%s\n' 'ERROR: no valid 3x-ui API token is available; no configuration was changed.' >&2
    return 1
  fi

  XUI_API_TOKEN="$token"
  XUI_API_TOKEN_SOURCE="$source"
  xui_store_token "$token" >/dev/null 2>&1 || true
  export XUI_BIN XUI_PORT XUI_WEB_BASE_PATH XUI_API_TOKEN XUI_API_TOKEN_SOURCE XUI_BASE
}

xui_auth_curl() {
  # Bearer token is supplied over FD 3, not embedded in curl argv.
  curl -fsS -H @/dev/fd/3 "$@" 3<<<"Authorization: Bearer ${XUI_API_TOKEN}"
}

xui_password_login_works() {
  local username="$1" password="$2" xui show port raw_path clean_path base body
  local tmp_dir cookie_jar csrf_file response_file csrf_token csrf_code login_code i
  [ -n "$username" ] && [ -n "$password" ] || return 1
  case "$username$password" in *$'\r'*|*$'\n'*) return 1 ;; esac
  xui="$(xui_find_bin)" || return 1
  show="$("$xui" setting -show 2>/dev/null || true)"
  port="$(printf '%s\n' "$show" | sed -nE 's/^[[:space:]]*(port|panelPort):[[:space:]]*([0-9]+).*$/\2/p' | sed -n '1p')"
  raw_path="$(printf '%s\n' "$show" | sed -nE 's/^[[:space:]]*(webBasePath|web base path):[[:space:]]*(.*)$/\2/p' | sed -n '1p')"
  [ -n "$port" ] || port="$(xui_env_value "${PNA_XUI_PUBLIC_FILE:-/etc/proxy-runbook/public.env}" PANEL_PORT 2>/dev/null || true)"
  [ -n "$raw_path" ] || raw_path="$(xui_env_value "${PNA_XUI_PUBLIC_FILE:-/etc/proxy-runbook/public.env}" WEB_BASE_PATH 2>/dev/null || true)"
  case "$port" in ''|*[!0-9]*) return 1 ;; esac
  [ "$port" -ge 1 ] && [ "$port" -le 65535 ] || return 1
  clean_path="${raw_path#/}"; clean_path="${clean_path%/}"
  base="http://127.0.0.1:${port}"
  [ -z "$clean_path" ] || base="${base}/${clean_path}"
  body="$(printf '%s\n%s' "$username" "$password" | python3 -c 'import sys, urllib.parse; u=sys.stdin.readline().rstrip("\n"); p=sys.stdin.read(); print(urllib.parse.urlencode({"username":u,"password":p,"twoFactorCode":""}), end="")')" || return 1
  tmp_dir="$(mktemp -d)" || return 1
  cookie_jar="$tmp_dir/cookies"
  csrf_file="$tmp_dir/csrf.json"
  response_file="$tmp_dir/login.json"

  # 3x-ui 3.6+ rejects a bare POST /login with HTTP 403. Mirror the browser:
  # fetch a CSRF token and session cookie first, then submit the form with both.
  # Credentials travel in curl's stdin, never in argv or command output.
  for i in 1 2 3 4 5 6 7 8; do
    : > "$cookie_jar"
    csrf_code="$(curl -sS --max-time 10 \
      -c "$cookie_jar" -b "$cookie_jar" \
      -H 'X-Requested-With: XMLHttpRequest' \
      -o "$csrf_file" -w '%{http_code}' \
      "${base}/csrf-token" 2>/dev/null || true)"
    csrf_token="$(jq -r 'if .success == true and (.obj | type) == "string" then .obj else empty end' "$csrf_file" 2>/dev/null || true)"
    if [ "$csrf_code" = "200" ] && [ -n "$csrf_token" ]; then
      login_code="$(printf '%s' "$body" | curl -sS --max-time 10 \
        -c "$cookie_jar" -b "$cookie_jar" \
        -H 'X-Requested-With: XMLHttpRequest' \
        -H "X-CSRF-Token: ${csrf_token}" \
        -H 'Content-Type: application/x-www-form-urlencoded; charset=UTF-8' \
        --data-binary @- -o "$response_file" -w '%{http_code}' \
        "${base}/login" 2>/dev/null || true)"
      if [ "$login_code" = "200" ] && jq -e '(.success == true) or (.success == "true")' "$response_file" >/dev/null 2>&1; then
        rm -rf -- "$tmp_dir"
        return 0
      fi
    fi
    sleep 1
  done
  rm -rf -- "$tmp_dir"
  return 1
}

xui_api_get() {
  local path="$1"
  xui_auth_curl "${XUI_BASE}${path}"
}

xui_api_post_json() {
  local path="$1" body="$2"
  xui_auth_curl -X POST \
    -H "Content-Type: application/json" \
    --data "$body" \
    "${XUI_BASE}${path}"
}

xui_new_uuid() {
  local response uuid
  response="$(xui_api_get "/panel/api/server/getNewUUID")" || return 1
  uuid="$(jq -r '
    if (.obj | type) == "string" then .obj
    elif (.obj | type) == "object" then (.obj.uuid // empty)
    else empty
    end
  ' <<<"$response" 2>/dev/null || true)"
  if ! [[ "$uuid" =~ ^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$ ]]; then
    echo "ERROR: 3x-ui returned an invalid UUID shape." >&2
    return 1
  fi
  printf '%s' "$uuid"
}
