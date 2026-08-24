#!/usr/bin/env bash

HANDOFF_DIR="/root/.config/proxy-runbook"
HANDOFF_FILE="${HANDOFF_DIR}/HANDOFF-SECRETS.txt"
HANDOFF_ARCHIVE="${HANDOFF_DIR}/handoff-archive"

handoff_init() {
  install -d -m 700 "$HANDOFF_DIR" "$HANDOFF_ARCHIVE"
  touch "$HANDOFF_FILE"
  chmod 600 "$HANDOFF_FILE"
}

handoff_begin_run() {
  handoff_init
  if [ -s "$HANDOFF_FILE" ]; then
    local stamp
    stamp="$(date +%Y%m%d-%H%M%S)"
    cp -a "$HANDOFF_FILE" "${HANDOFF_ARCHIVE}/HANDOFF-${stamp}.txt"
    chmod 600 "${HANDOFF_ARCHIVE}/HANDOFF-${stamp}.txt"
  fi
  : > "$HANDOFF_FILE"
  chmod 600 "$HANDOFF_FILE"
  printf 'HANDOFF_RUN_STARTED=%s\n' "$(date -Is)" >> "$HANDOFF_FILE"
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
