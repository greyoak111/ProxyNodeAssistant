#!/usr/bin/env bash

PNA_DEPLOYMENT_STATE_FILE="${PNA_DEPLOYMENT_STATE_FILE:-/etc/proxy-runbook/deployment-state.env}"
PNA_DEPLOYMENT_LOCK_FILE="${PNA_DEPLOYMENT_LOCK_FILE:-/run/lock/proxy-node-assistant-deployment.lock}"

pna_valid_deployment_mode() {
  case "${1:-}" in direct-reality|cdn-xhttp-tls|dual-hot-switch) return 0;; *) return 1;; esac
}

pna_valid_deployment_state() {
  case "${1:-}" in
    ACTIVE_DIRECT|ACTIVE_CDN|CDN_STAGED_8443|WAITING_FOR_CLOUDFLARE_MANUAL_ACTION|\
    DUAL_INSTALLED_ACTIVE_DIRECT|DUAL_INSTALLED_ACTIVE_CDN|\
    SWITCH_TO_CDN_STAGED_8443|SWITCH_TO_CDN_PORT_443_COMMITTING|\
    SWITCH_TO_DIRECT_STAGED_24443|SWITCH_TO_DIRECT_PORT_443_COMMITTING) return 0 ;;
    *) return 1 ;;
  esac
}

pna_valid_443_owner() {
  case "${1:-}" in xray-reality|nginx-cdn|none) return 0;; *) return 1;; esac
}

pna_state_env_value() {
  local key="${1:?key required}" line
  [ -r "$PNA_DEPLOYMENT_STATE_FILE" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in "${key}="*) printf '%s\n' "${line#*=}"; return 0;; esac
  done < "$PNA_DEPLOYMENT_STATE_FILE"
  return 1
}

pna_state_write_unlocked() {
  local mode="${1:?mode required}" state="${2:?state required}" owner="${3:?owner required}"
  local history="${4:-unknown}" generation="${5:-1}" tmp dir
  pna_valid_deployment_mode "$mode" || return 81
  pna_valid_deployment_state "$state" || return 81
  pna_valid_443_owner "$owner" || return 81
  case "$history" in clean|previously-exposed|unknown) ;; *) return 81;; esac
  case "$generation" in ''|*[!0-9]*) return 81;; esac
  dir="$(dirname "$PNA_DEPLOYMENT_STATE_FILE")"
  install -d -m 755 "$dir"
  tmp="$(mktemp "${dir}/.deployment-state.XXXXXX")"
  {
    printf 'PNA_STATE_VERSION=1\n'
    printf 'DEPLOYMENT_MODE=%s\n' "$mode"
    printf 'ACTIVE_MODE=%s\n' "$state"
    printf 'PORT_443_OWNER=%s\n' "$owner"
    printf 'ORIGIN_HISTORY=%s\n' "$history"
    printf 'STATE_GENERATION=%s\n' "$generation"
    printf 'STATE_UPDATED_AT=%s\n' "$(date -Is)"
  } > "$tmp"
  chmod 644 "$tmp"
  mv -f -- "$tmp" "$PNA_DEPLOYMENT_STATE_FILE"
}

pna_state_init_direct_if_missing() {
  [ -s "$PNA_DEPLOYMENT_STATE_FILE" ] && return 0
  command -v flock >/dev/null 2>&1 || { echo 'PNA_STATE_ERROR=FLOCK_MISSING' >&2; return 82; }
  install -d -m 755 "$(dirname "$PNA_DEPLOYMENT_LOCK_FILE")"
  exec 9>"$PNA_DEPLOYMENT_LOCK_FILE"
  flock -x 9
  [ -s "$PNA_DEPLOYMENT_STATE_FILE" ] || pna_state_write_unlocked direct-reality ACTIVE_DIRECT xray-reality previously-exposed 1
  flock -u 9
}

pna_state_show() {
  [ -r "$PNA_DEPLOYMENT_STATE_FILE" ] || { echo 'PNA_STATE_ERROR=MISSING' >&2; return 83; }
  local mode state owner history generation
  mode="$(pna_state_env_value DEPLOYMENT_MODE || true)"
  state="$(pna_state_env_value ACTIVE_MODE || true)"
  owner="$(pna_state_env_value PORT_443_OWNER || true)"
  history="$(pna_state_env_value ORIGIN_HISTORY || true)"
  generation="$(pna_state_env_value STATE_GENERATION || true)"
  pna_valid_deployment_mode "$mode" && pna_valid_deployment_state "$state" && pna_valid_443_owner "$owner" || {
    echo 'PNA_STATE_ERROR=INVALID' >&2; return 84;
  }
  printf '__PNA_DEPLOYMENT_STATE_BEGIN__\n'
  printf 'DEPLOYMENT_MODE=%s\nACTIVE_MODE=%s\nPORT_443_OWNER=%s\nORIGIN_HISTORY=%s\nSTATE_GENERATION=%s\n' \
    "$mode" "$state" "$owner" "$history" "$generation"
  printf '__PNA_DEPLOYMENT_STATE_END__\n'
}

pna_transition_allowed() {
  local from="${1:-}" to="${2:-}"
  [ "$from" = "$to" ] && return 0
  case "${from}:${to}" in
    ACTIVE_DIRECT:CDN_STAGED_8443|\
    ACTIVE_DIRECT:DUAL_INSTALLED_ACTIVE_DIRECT|\
    CDN_STAGED_8443:WAITING_FOR_CLOUDFLARE_MANUAL_ACTION|\
    CDN_STAGED_8443:ACTIVE_DIRECT|\
    WAITING_FOR_CLOUDFLARE_MANUAL_ACTION:ACTIVE_DIRECT|\
    WAITING_FOR_CLOUDFLARE_MANUAL_ACTION:SWITCH_TO_CDN_STAGED_8443|\
    WAITING_FOR_CLOUDFLARE_MANUAL_ACTION:SWITCH_TO_DIRECT_STAGED_24443|\
    WAITING_FOR_CLOUDFLARE_MANUAL_ACTION:DUAL_INSTALLED_ACTIVE_DIRECT|\
    WAITING_FOR_CLOUDFLARE_MANUAL_ACTION:DUAL_INSTALLED_ACTIVE_CDN|\
    DUAL_INSTALLED_ACTIVE_DIRECT:SWITCH_TO_CDN_STAGED_8443|\
    SWITCH_TO_CDN_STAGED_8443:WAITING_FOR_CLOUDFLARE_MANUAL_ACTION|\
    SWITCH_TO_CDN_STAGED_8443:DUAL_INSTALLED_ACTIVE_DIRECT|\
    SWITCH_TO_CDN_STAGED_8443:SWITCH_TO_CDN_PORT_443_COMMITTING|\
    SWITCH_TO_CDN_PORT_443_COMMITTING:DUAL_INSTALLED_ACTIVE_CDN|\
    SWITCH_TO_CDN_PORT_443_COMMITTING:DUAL_INSTALLED_ACTIVE_DIRECT|\
    ACTIVE_CDN:SWITCH_TO_DIRECT_STAGED_24443|\
    ACTIVE_CDN:DUAL_INSTALLED_ACTIVE_CDN|\
    DUAL_INSTALLED_ACTIVE_CDN:SWITCH_TO_DIRECT_STAGED_24443|\
    SWITCH_TO_DIRECT_STAGED_24443:WAITING_FOR_CLOUDFLARE_MANUAL_ACTION|\
    SWITCH_TO_DIRECT_STAGED_24443:DUAL_INSTALLED_ACTIVE_CDN|\
    SWITCH_TO_DIRECT_STAGED_24443:SWITCH_TO_DIRECT_PORT_443_COMMITTING|\
    SWITCH_TO_DIRECT_PORT_443_COMMITTING:DUAL_INSTALLED_ACTIVE_DIRECT|\
    SWITCH_TO_DIRECT_PORT_443_COMMITTING:DUAL_INSTALLED_ACTIVE_CDN) return 0 ;;
    *) return 1 ;;
  esac
}

pna_state_transition() {
  local expected="${1:?expected state required}" next="${2:?next state required}"
  local mode="${3:?mode required}" owner="${4:?owner required}" history="${5:-unknown}"
  local current generation
  command -v flock >/dev/null 2>&1 || { echo 'PNA_STATE_ERROR=FLOCK_MISSING' >&2; return 82; }
  install -d -m 755 "$(dirname "$PNA_DEPLOYMENT_LOCK_FILE")"
  exec 9>"$PNA_DEPLOYMENT_LOCK_FILE"
  flock -x 9
  current="$(pna_state_env_value ACTIVE_MODE || true)"
  [ "$current" = "$expected" ] || { echo "PNA_STATE_ERROR=EXPECTED_${expected}_GOT_${current:-MISSING}" >&2; flock -u 9; return 85; }
  pna_transition_allowed "$current" "$next" || { echo "PNA_STATE_ERROR=UNSAFE_TRANSITION_${current}_TO_${next}" >&2; flock -u 9; return 86; }
  generation="$(pna_state_env_value STATE_GENERATION || true)"
  case "$generation" in ''|*[!0-9]*) generation=0;; esac
  generation=$((generation + 1))
  pna_state_write_unlocked "$mode" "$next" "$owner" "$history" "$generation"
  flock -u 9
}
