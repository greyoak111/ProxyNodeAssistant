#!/usr/bin/env bash

# The reset line writes new handoffs below proxy-runbook, while v0.9.x wrote
# them below text-node-assistant. Keep both locations readable so an upgrade
# never strands VPS/panel credentials or protocol links. PNA_HANDOFF_DIR is
# useful for isolated tests; TNA_HANDOFF_DIR remains the v0.9.x override.
HANDOFF_DIR="${PNA_HANDOFF_DIR:-${TNA_HANDOFF_DIR:-/root/.config/proxy-runbook}}"
LEGACY_HANDOFF_DIR="${PNA_LEGACY_HANDOFF_DIR:-/root/.config/text-node-assistant}"
HANDOFF_FILE="${HANDOFF_DIR}/HANDOFF-SECRETS.txt"
HANDOFF_ARCHIVE="${HANDOFF_DIR}/handoff-archive"
HANDOFF_LOGIN_STORE="${HANDOFF_DIR}/CURRENT-LOGIN-CREDENTIALS.env"

handoff_init() {
  install -d -m 700 "$HANDOFF_DIR" "$HANDOFF_ARCHIVE"
  touch "$HANDOFF_FILE"
  chmod 600 "$HANDOFF_FILE"
}

handoff_legacy_files() {
  # Do not emit duplicate paths when a test deliberately points both roots at
  # the same directory.
  [ "$LEGACY_HANDOFF_DIR" = "$HANDOFF_DIR" ] || printf '%s\n' \
    "$LEGACY_HANDOFF_DIR/HANDOFF-SECRETS.txt"
  [ "$LEGACY_HANDOFF_DIR" = "$HANDOFF_DIR" ] || [ ! -d "$LEGACY_HANDOFF_DIR/handoff-archive" ] || \
    find "$LEGACY_HANDOFF_DIR/handoff-archive" -maxdepth 1 -type f -name 'HANDOFF-*.txt' \
      -printf '%T@ %p\n' 2>/dev/null | sort -nr | while IFS= read -r entry; do
        printf '%s\n' "${entry#* }"
      done
}

handoff_all_candidate_files() {
  printf '%s\n' "$HANDOFF_FILE"
  if [ -d "$HANDOFF_ARCHIVE" ]; then
    find "$HANDOFF_ARCHIVE" -maxdepth 1 -type f -name 'HANDOFF-*.txt' \
      -printf '%T@ %p\n' 2>/dev/null | sort -nr | while IFS= read -r entry; do
        printf '%s\n' "${entry#* }"
      done
  fi
  handoff_legacy_files
}

handoff_begin_run() {
  handoff_init
  credential_store_seed_from_handoffs
  if [ -s "$HANDOFF_FILE" ]; then
    local stamp
    stamp="$(date +%Y%m%d-%H%M%S)"
    cp -a -- "$HANDOFF_FILE" "${HANDOFF_ARCHIVE}/HANDOFF-${stamp}.txt"
    chmod 600 "${HANDOFF_ARCHIVE}/HANDOFF-${stamp}.txt"
  fi
  : > "$HANDOFF_FILE"
  chmod 600 "$HANDOFF_FILE"
  printf 'HANDOFF_RUN_STARTED=%s\n' "$(date -Is)" >> "$HANDOFF_FILE"
  handoff_restore_stored_login_credentials
}

credential_value_from_file() {
  local file="$1" key="$2" value
  [ -r "$file" ] || return 1
  # Handoff files are line-oriented and older runs may contain a stale
  # placeholder followed by a real value (or the reverse after a failed
  # rotation).  Match the parser's last-value-wins semantics, while ignoring
  # known non-credentials so a valid archived value can still be migrated.
  value="$(awk -v wanted="$key" '
    index($0, wanted "=")==1 {
      candidate=substr($0, length(wanted)+2)
      upper=toupper(candidate)
      if (candidate != "" && upper !~ /^(UNKNOWN|NOT_RETAINED|SSH_KEY_ONLY)/) value=candidate
    }
    END {print value}
  ' "$file" 2>/dev/null || true)"
  case "$value" in
    ''|UNKNOWN*|NOT_RETAINED*|SSH_KEY_ONLY) return 1 ;;
  esac
  # Bash variables cannot contain NUL bytes; CR/LF are the meaningful shell
  # injection cases to reject here.
  case "$value" in *$'\r'*|*$'\n'*) return 1 ;; esac
  printf '%s\n' "$value"
}

credential_store_set() {
  local key="$1" value="$2" tmp
  case "$key" in
    VPS_LOGIN_USER|VPS_LOGIN_PASSWORD|PANEL_USERNAME|PANEL_PASSWORD) ;;
    *) return 2 ;;
  esac
  case "$value" in
    ''|*$'\r'*|*$'\n'*|UNKNOWN*|NOT_RETAINED*|SSH_KEY_ONLY) return 2 ;;
  esac
  handoff_init
  tmp="$(mktemp "${HANDOFF_DIR}/.login-credentials.XXXXXX")" || return 1
  if [ -r "$HANDOFF_LOGIN_STORE" ]; then
    awk -v wanted="$key" 'index($0, wanted "=") != 1 {print}' "$HANDOFF_LOGIN_STORE" > "$tmp" || true
  fi
  printf '%s=%s\n' "$key" "$value" >> "$tmp"
  chmod 600 "$tmp"
  mv -f -- "$tmp" "$HANDOFF_LOGIN_STORE"
}

credential_store_delete_pair() {
  local prefix="$1" tmp
  handoff_init
  [ -r "$HANDOFF_LOGIN_STORE" ] || return 0
  tmp="$(mktemp "${HANDOFF_DIR}/.login-credentials.XXXXXX")" || return 1
  awk -v prefix="$prefix" 'index($0, prefix "_") != 1 {print}' "$HANDOFF_LOGIN_STORE" > "$tmp" || true
  chmod 600 "$tmp"
  mv -f -- "$tmp" "$HANDOFF_LOGIN_STORE"
}

credential_store_seed_pair() {
  local key_user="$1" key_password="$2" file user password
  # Prefer a complete current store. If it is incomplete, a legacy store or
  # any archived handoff may still contain the pair.
  if credential_value_from_file "$HANDOFF_LOGIN_STORE" "$key_user" >/dev/null 2>&1 &&
     credential_value_from_file "$HANDOFF_LOGIN_STORE" "$key_password" >/dev/null 2>&1; then
    return 0
  fi
  if [ "$LEGACY_HANDOFF_DIR" != "$HANDOFF_DIR" ] && [ -r "$LEGACY_HANDOFF_DIR/CURRENT-LOGIN-CREDENTIALS.env" ]; then
    user="$(credential_value_from_file "$LEGACY_HANDOFF_DIR/CURRENT-LOGIN-CREDENTIALS.env" "$key_user" 2>/dev/null || true)"
    password="$(credential_value_from_file "$LEGACY_HANDOFF_DIR/CURRENT-LOGIN-CREDENTIALS.env" "$key_password" 2>/dev/null || true)"
    if [ -n "$user" ] && [ -n "$password" ]; then
      credential_store_set "$key_user" "$user"
      credential_store_set "$key_password" "$password"
      return 0
    fi
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
  done < <(handoff_all_candidate_files)
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
  local key file found
  for key in VPS_LOGIN_USER VPS_LOGIN_PASSWORD PANEL_USERNAME PANEL_PASSWORD; do
    found=0
    while IFS= read -r file; do
      [ -n "$file" ] || continue
      if credential_value_from_file "$file" "$key" >/dev/null 2>&1; then
        found=1
        break
      fi
    # A failed rotation can leave the current handoff with a placeholder while
    # the last usable value is still in an archive.  Use the same candidate
    # set as credential_store_seed_pair so standalone exporters and the full
    # installer agree on what constitutes a complete login form.
    done < <(handoff_all_candidate_files)
    if [ "$found" -ne 1 ]; then
      printf 'LOGIN_CREDENTIAL_FORM_INCOMPLETE missing=%s\n' "$key" >&2
      return 1
    fi
  done
  return 0
}

handoff_set() {
  local key="$1" value="$2" tmp
  [[ "$key" =~ ^[A-Z][A-Z0-9_]{0,63}$ ]] || return 2
  case "$value" in *$'\r'*|*$'\n'*) return 2 ;; esac
  handoff_init
  tmp="$(mktemp "${HANDOFF_DIR}/.handoff.XXXXXX")" || return 1
  awk -v wanted="$key" 'index($0, wanted "=") != 1 {print}' "$HANDOFF_FILE" > "$tmp" || true
  printf '%s=%s\n' "$key" "$value" >> "$tmp"
  install -m 600 "$tmp" "$HANDOFF_FILE"
  rm -f -- "$tmp"
}

handoff_delete() {
  local key="$1" tmp
  [[ "$key" =~ ^[A-Z][A-Z0-9_]{0,63}$ ]] || return 2
  handoff_init
  tmp="$(mktemp "${HANDOFF_DIR}/.handoff.XXXXXX")" || return 1
  awk -v wanted="$key" 'index($0, wanted "=") != 1 {print}' "$HANDOFF_FILE" > "$tmp" || true
  install -m 600 "$tmp" "$HANDOFF_FILE"
  rm -f -- "$tmp"
}

handoff_note() {
  handoff_init
  case "$*" in *$'\r'*|*$'\n'*) return 2 ;; esac
  printf '%s\n' "$*" >> "$HANDOFF_FILE"
}

# Render a handoff without replaying presentation wrappers that may have been
# copied into a v0.9.x state file.  The desktop/Android clients perform the
# same canonicalization before adding their v1 appendix; keeping the direct
# maintenance-menu path consistent prevents an old `END TNA ...` line from
# appearing when an operator invokes the toolkit menu itself.
handoff_display_file() {
  local file="$1"
  [ -r "$file" ] || return 0
  awk '
    {
      line=$0
      upper=toupper(line)
      if (upper ~ /COMPLETE HANDOFF|REQUIRED LOGIN CREDENTIALS|REAL CREDENTIAL HANDOFF|CURRENT 3X-UI HANDOFF|REAL GENERATED REALITY|MANDATORY DRIVE|ORDINARY DRIVE|PRIVATE DRIVE/) next
      if (line ~ /^[[:space:]]*__(PNA|TNA)_HANDOFF_(BEGIN|END)__[[:space:]]*$/) next
      # Retire the complete v0.9.5 admission/drive/admin vocabulary, including
      # bare keys such as CURRENT_DEVICE_ID that do not share a DEVICE_ prefix.
      # Match the key separately from its value so a credential containing one
      # of these words is never discarded accidentally.
      key=line
      sub(/^[[:space:]]*/, "", key)
      equal=index(key, "=")
      if (equal > 0) {
        key=substr(key, 1, equal-1)
        gsub(/[[:space:]]+$/, "", key)
        key=toupper(key)
        if (key == "CURRENT_DEVICE_ID" || key == "LOCAL_DEVICE_ID" || key == "DEVICE_ID" || key == "DEVICE_ROLE" || key == "DEVICE_PUBLIC_KEY" || key == "ENCRYPTION_PUBLIC_KEY" || key == "PRIVATE_IDENTITY_STORAGE" || key == "DEVICE_ADMISSION" || key == "INVITE_POLICY" || key == "ACTIVE_CONTROLLERS" || key == "ACTIVE_DEVICES" || key == "PER_DEVICE_VLESS" || key == "CDN_MTLS_DEVICE" || key == "WIREGUARD_DEVICE_LOCK" || key == "OWNER_DEVICE_ID" || key == "FENCING_TOKEN" || key == "CURRENT_STAGE" || key == "LAST_HEARTBEAT" || key == "TNA_VERSION") next
        if (key ~ /^(PRIVATE_DRIVE_|DRIVE_|MANDATORY_DRIVE_|LOCAL_ADMIN_|TNA_LOCAL_ADMIN_|DEVICE_|TNA_DEVICE_|PNA_DEVICE_|CONTROLLER_|TNA_CONTROLLER_|PNA_CONTROLLER_|NODE_OPERATION_|LEASE_|INVITE_|INVITATION_)/) next

        # v0.9.x exported CDN links under XHTTP_* aliases and used TNA-*
        # fragments.  Keep the handoff file untouched for migration, but make
        # the maintenance display emit one canonical PNA key/value.  RawQuery
        # bytes (including x_padding_bytes/extra) remain unchanged because the
        # substitution only touches the terminal fragment.
        if (key == "CDN_XHTTP_LINK" || key == "XHTTP_LINK" || key == "CDN_XHTTP_STAGE_LINK" || key == "XHTTP_STAGE_LINK") {
          canonical_key = (key == "CDN_XHTTP_STAGE_LINK" || key == "XHTTP_STAGE_LINK") ? "CDN_XHTTP_STAGE_LINK" : "CDN_XHTTP_LINK"
          value = substr(line, equal + 1)
          sub(/^[[:space:]]+/, "", value)
          sub(/[[:space:]]+$/, "", value)
          if (value ~ /#TNA-CDN-XHTTP-STAGE$/) {
            sub(/#TNA-CDN-XHTTP-STAGE$/, "#PNA-CDN-XHTTP-STAGE", value)
          } else if (value ~ /#TNA-CDN-XHTTP-ORANGE$/) {
            sub(/#TNA-CDN-XHTTP-ORANGE$/, "#PNA-CDN-XHTTP-ORANGE", value)
          } else if (value ~ /#TNA-CDN-XHTTP$/) {
            sub(/#TNA-CDN-XHTTP$/, "#PNA-CDN-XHTTP", value)
          }
          # Last-value-wins mirrors credential/parser behavior when a failed
          # rotation left duplicate canonical and legacy aliases in one file.
          link_key[NR] = canonical_key
          link_value[canonical_key] = value
          link_last[canonical_key] = NR
          next
        }
      } else if (upper ~ /^[[:space:]]*(DEVICE|CONTROLLER)[[:space:]]/) next
      kept[NR] = line
    }
    END {
      for (i = 1; i <= NR; i++) {
        if (link_key[i] != "") {
          key = link_key[i]
          if (link_last[key] == i) print key "=" link_value[key]
        } else if (i in kept) {
          print kept[i]
        }
      }
    }
  ' "$file"
}

handoff_show() {
  handoff_init
  echo
  echo "===== PROXYNODEASSISTANT CREDENTIAL HANDOFF v1.0.0 ====="
  handoff_display_file "$HANDOFF_FILE"
  echo "===== END PROXYNODEASSISTANT CREDENTIAL HANDOFF v1.0.0 ====="
  echo "Root-only copy on VPS: $HANDOFF_FILE"
  echo "Legacy handoff (read-only migration source): $LEGACY_HANDOFF_DIR/HANDOFF-SECRETS.txt"
  echo "Previous run handoffs, if any: $HANDOFF_ARCHIVE"
  echo "Save current generated values in your password manager now."
  echo "Do NOT paste this block into a public issue/chat/repo."
}
