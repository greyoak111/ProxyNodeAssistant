#!/usr/bin/env bash

HANDOFF_DIR="${PNA_HANDOFF_DIR:-/root/.config/proxy-runbook}"
HANDOFF_FILE="${HANDOFF_DIR}/HANDOFF-SECRETS.txt"
HANDOFF_ARCHIVE="${HANDOFF_DIR}/handoff-archive"
HANDOFF_LOGIN_STORE="${HANDOFF_DIR}/CURRENT-LOGIN-CREDENTIALS.env"

handoff_init() {
  install -d -m 700 "$HANDOFF_DIR" "$HANDOFF_ARCHIVE"
  touch "$HANDOFF_FILE"
  chmod 600 "$HANDOFF_FILE"
}

handoff_begin_run() {
  handoff_init
  credential_store_seed_from_handoffs
  if [ -s "$HANDOFF_FILE" ]; then
    local stamp
    stamp="$(date +%Y%m%d-%H%M%S)"
    cp -a "$HANDOFF_FILE" "${HANDOFF_ARCHIVE}/HANDOFF-${stamp}.txt"
    chmod 600 "${HANDOFF_ARCHIVE}/HANDOFF-${stamp}.txt"
  fi
  : > "$HANDOFF_FILE"
  chmod 600 "$HANDOFF_FILE"
  printf 'HANDOFF_RUN_STARTED=%s\n' "$(date -Is)" >> "$HANDOFF_FILE"
  handoff_restore_stored_login_credentials
}

credential_value_from_file() {
  local file="$1" key="$2" line value
  [ -r "$file" ] || return 1
  line="$(grep -m1 "^${key}=" "$file" 2>/dev/null || true)"
  [ -n "$line" ] || return 1
  value="${line#*=}"
  case "$value" in ''|UNKNOWN*|NOT_RETAINED*|SSH_KEY_ONLY) return 1 ;; esac
  printf '%s\n' "$value"
}

credential_store_set() {
  local key="$1" value="$2" tmp
  case "$key" in VPS_LOGIN_USER|VPS_LOGIN_PASSWORD|PANEL_USERNAME|PANEL_PASSWORD) ;; *) return 2 ;; esac
  case "$value" in ''|*$'\r'*|*$'\n'*|UNKNOWN*|NOT_RETAINED*|SSH_KEY_ONLY) return 2 ;; esac
  handoff_init
  tmp="$(mktemp "${HANDOFF_DIR}/.login-credentials.XXXXXX")"
  [ ! -r "$HANDOFF_LOGIN_STORE" ] || grep -v "^${key}=" "$HANDOFF_LOGIN_STORE" > "$tmp" || true
  printf '%s=%s\n' "$key" "$value" >> "$tmp"
  chmod 600 "$tmp"
  mv -f -- "$tmp" "$HANDOFF_LOGIN_STORE"
}

credential_store_delete_pair() {
  local prefix="$1" tmp
  handoff_init
  [ -r "$HANDOFF_LOGIN_STORE" ] || return 0
  tmp="$(mktemp "${HANDOFF_DIR}/.login-credentials.XXXXXX")"
  grep -v "^${prefix}_" "$HANDOFF_LOGIN_STORE" > "$tmp" || true
  chmod 600 "$tmp"
  mv -f -- "$tmp" "$HANDOFF_LOGIN_STORE"
}

credential_store_seed_pair() {
  local key_user="$1" key_password="$2" file user password entry
  if credential_value_from_file "$HANDOFF_LOGIN_STORE" "$key_user" >/dev/null 2>&1 &&
     credential_value_from_file "$HANDOFF_LOGIN_STORE" "$key_password" >/dev/null 2>&1; then
    return 0
  fi
  while IFS= read -r file; do
    [ -n "$file" ] || continue
    user="$(credential_value_from_file "$file" "$key_user" 2>/dev/null || true)"
    password="$(credential_value_from_file "$file" "$key_password" 2>/dev/null || true)"
    if [ -n "$user" ] && [ -n "$password" ]; then
      credential_store_set "$key_user" "$user"
      credential_store_set "$key_password" "$password"
      return 0
    fi
  done < <(
    printf '%s\n' "$HANDOFF_FILE"
    find "$HANDOFF_ARCHIVE" -maxdepth 1 -type f -name 'HANDOFF-*.txt' -printf '%T@ %p\n' 2>/dev/null |
      sort -nr | while IFS= read -r entry; do printf '%s\n' "${entry#* }"; done
  )
  return 1
}

credential_store_seed_from_handoffs() {
  handoff_init
  touch "$HANDOFF_LOGIN_STORE"
  chmod 600 "$HANDOFF_LOGIN_STORE"
  credential_store_seed_pair VPS_LOGIN_USER VPS_LOGIN_PASSWORD || true
  credential_store_seed_pair PANEL_USERNAME PANEL_PASSWORD || true
}

handoff_restore_stored_login_credentials() {
  local key value
  for key in VPS_LOGIN_USER VPS_LOGIN_PASSWORD PANEL_USERNAME PANEL_PASSWORD; do
    value="$(credential_value_from_file "$HANDOFF_LOGIN_STORE" "$key" 2>/dev/null || true)"
    [ -n "$value" ] && handoff_set "$key" "$value"
  done
}

handoff_login_form_complete() {
  local key
  for key in VPS_LOGIN_USER VPS_LOGIN_PASSWORD PANEL_USERNAME PANEL_PASSWORD; do
    credential_value_from_file "$HANDOFF_FILE" "$key" >/dev/null 2>&1 || {
      printf 'LOGIN_CREDENTIAL_FORM_INCOMPLETE missing=%s\n' "$key" >&2
      return 1
    }
  done
  return 0
}

handoff_set() {
  local key="$1" value="$2" tmp
  handoff_init
  tmp="$(mktemp)"
  grep -v "^${key}=" "$HANDOFF_FILE" > "$tmp" || true
  printf '%s=%s\n' "$key" "$value" >> "$tmp"
  install -m 600 "$tmp" "$HANDOFF_FILE"
  rm -f "$tmp"
}

handoff_delete() {
  local key="$1" tmp
  handoff_init
  tmp="$(mktemp)"
  grep -v "^${key}=" "$HANDOFF_FILE" > "$tmp" || true
  install -m 600 "$tmp" "$HANDOFF_FILE"
  rm -f "$tmp"
}

handoff_note() {
  handoff_init
  printf '%s\n' "$*" >> "$HANDOFF_FILE"
}

handoff_show() {
  handoff_init
  echo
  echo "================ REAL CREDENTIAL HANDOFF ================"
  cat "$HANDOFF_FILE"
  echo "========================================================="
  echo "Root-only copy on VPS: $HANDOFF_FILE"
  echo "Previous run handoffs, if any: $HANDOFF_ARCHIVE"
  echo "Save current generated values in your password manager now."
  echo "Do NOT paste this block into a public issue/chat/repo."
}
