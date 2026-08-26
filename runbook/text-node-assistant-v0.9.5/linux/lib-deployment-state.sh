#!/usr/bin/env bash

TNA_DEPLOYMENT_STATE_FILE="${TNA_DEPLOYMENT_STATE_FILE:-/etc/text-node-assistant/deployment-state.env}"
TNA_DEPLOYMENT_LOCK_FILE="${TNA_DEPLOYMENT_LOCK_FILE:-/run/lock/text-node-assistant-deployment.lock}"

tna_valid_deployment_mode() {
  case "${1:-}" in direct-reality|cdn-xhttp-tls|dual-hot-switch) return 0;; *) return 1;; esac
}

tna_valid_deployment_state() {
  case "${1:-}" in
    ACTIVE_DIRECT|ACTIVE_CDN|CDN_STAGED_8443|WAITING_FOR_CLOUDFLARE_MANUAL_ACTION|\
    DUAL_INSTALLED_ACTIVE_DIRECT|DUAL_INSTALLED_ACTIVE_CDN|\
    SWITCH_TO_CDN_STAGED_8443|SWITCH_TO_CDN_PORT_443_COMMITTING|\
    SWITCH_TO_DIRECT_STAGED_24443|SWITCH_TO_DIRECT_PORT_443_COMMITTING) return 0 ;;
    *) return 1 ;;
  esac
}

tna_valid_443_owner() {
  case "${1:-}" in xray-reality|nginx-cdn|none) return 0;; *) return 1;; esac
}

tna_state_env_value() {
  local key="${1:?key required}" line
  [ -r "$TNA_DEPLOYMENT_STATE_FILE" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in "${key}="*) printf '%s\n' "${line#*=}"; return 0;; esac
  done < "$TNA_DEPLOYMENT_STATE_FILE"
  return 1
}

tna_state_write_unlocked() {
  local mode="${1:?mode required}" state="${2:?state required}" owner="${3:?owner required}"
  local history="${4:-unknown}" generation="${5:-1}" tmp dir
  tna_valid_deployment_mode "$mode" || return 81
  tna_valid_deployment_state "$state" || return 81
  tna_valid_443_owner "$owner" || return 81
  case "$history" in clean|previously-exposed|unknown) ;; *) return 81;; esac
  case "$generation" in ''|*[!0-9]*) return 81;; esac
  dir="$(dirname "$TNA_DEPLOYMENT_STATE_FILE")"
  install -d -m 755 "$dir"
  tmp="$(mktemp "${dir}/.deployment-state.XXXXXX")"
  {
    printf 'TNA_STATE_VERSION=1\n'
    printf 'DEPLOYMENT_MODE=%s\n' "$mode"
    printf 'ACTIVE_MODE=%s\n' "$state"
    printf 'PORT_443_OWNER=%s\n' "$owner"
    printf 'ORIGIN_HISTORY=%s\n' "$history"
    printf 'STATE_GENERATION=%s\n' "$generation"
    printf 'STATE_UPDATED_AT=%s\n' "$(date -Is)"
  } > "$tmp"
  chmod 644 "$tmp"
  mv -f -- "$tmp" "$TNA_DEPLOYMENT_STATE_FILE"
}

tna_state_init_direct_if_missing() {
  [ -s "$TNA_DEPLOYMENT_STATE_FILE" ] && return 0
  command -v flock >/dev/null 2>&1 || { echo 'TNA_STATE_ERROR=FLOCK_MISSING' >&2; return 82; }
  install -d -m 755 "$(dirname "$TNA_DEPLOYMENT_LOCK_FILE")"
  exec 9>"$TNA_DEPLOYMENT_LOCK_FILE"
  flock -x 9
  [ -s "$TNA_DEPLOYMENT_STATE_FILE" ] || tna_state_write_unlocked direct-reality ACTIVE_DIRECT xray-reality previously-exposed 1
  flock -u 9
}

tna_state_show() {
  [ -r "$TNA_DEPLOYMENT_STATE_FILE" ] || { echo 'TNA_STATE_ERROR=MISSING' >&2; return 83; }
  local mode state owner history generation
  mode="$(tna_state_env_value DEPLOYMENT_MODE || true)"
  state="$(tna_state_env_value ACTIVE_MODE || true)"
  owner="$(tna_state_env_value PORT_443_OWNER || true)"
  history="$(tna_state_env_value ORIGIN_HISTORY || true)"
  generation="$(tna_state_env_value STATE_GENERATION || true)"
  tna_valid_deployment_mode "$mode" && tna_valid_deployment_state "$state" && tna_valid_443_owner "$owner" || {
    echo 'TNA_STATE_ERROR=INVALID' >&2; return 84;
  }
  printf '__TNA_DEPLOYMENT_STATE_BEGIN__\n'
  printf 'DEPLOYMENT_MODE=%s\nACTIVE_MODE=%s\nPORT_443_OWNER=%s\nORIGIN_HISTORY=%s\nSTATE_GENERATION=%s\n' \
    "$mode" "$state" "$owner" "$history" "$generation"
  printf '__TNA_DEPLOYMENT_STATE_END__\n'
}

tna_transition_allowed() {
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
    DUAL_INSTALLED_ACTIVE_DIRECT:ACTIVE_DIRECT|\
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

tna_state_transition() {
  local expected="${1:?expected state required}" next="${2:?next state required}"
  local mode="${3:?mode required}" owner="${4:?owner required}" history="${5:-unknown}"
  local current generation
  command -v flock >/dev/null 2>&1 || { echo 'TNA_STATE_ERROR=FLOCK_MISSING' >&2; return 82; }
  install -d -m 755 "$(dirname "$TNA_DEPLOYMENT_LOCK_FILE")"
  exec 9>"$TNA_DEPLOYMENT_LOCK_FILE"
  flock -x 9
  current="$(tna_state_env_value ACTIVE_MODE || true)"
  [ "$current" = "$expected" ] || { echo "TNA_STATE_ERROR=EXPECTED_${expected}_GOT_${current:-MISSING}" >&2; flock -u 9; return 85; }
  tna_transition_allowed "$current" "$next" || { echo "TNA_STATE_ERROR=UNSAFE_TRANSITION_${current}_TO_${next}" >&2; flock -u 9; return 86; }
  generation="$(tna_state_env_value STATE_GENERATION || true)"
  case "$generation" in ''|*[!0-9]*) generation=0;; esac
  generation=$((generation + 1))
  tna_state_write_unlocked "$mode" "$next" "$owner" "$history" "$generation"
  flock -u 9
}

# Commit a topology only after every route-specific runtime probe has passed.
# This is intentionally separate from the staged transition graph: a topology
# conversion can legitimately pass through several temporary states, while the
# committed state must describe the final listeners that actually remain.
tna_state_commit_converged() {
  local mode="${1:?mode required}" state="${2:?state required}"
  local owner="${3:?owner required}" history="${4:-unknown}"
  local generation
  tna_valid_deployment_mode "$mode" || return 81
  tna_valid_deployment_state "$state" || return 81
  tna_valid_443_owner "$owner" || return 81
  command -v flock >/dev/null 2>&1 || { echo 'TNA_STATE_ERROR=FLOCK_MISSING' >&2; return 82; }
  install -d -m 755 "$(dirname "$TNA_DEPLOYMENT_LOCK_FILE")"
  exec 9>"$TNA_DEPLOYMENT_LOCK_FILE"
  flock -x 9
  generation="$(tna_state_env_value STATE_GENERATION || true)"
  case "$generation" in ''|*[!0-9]*) generation=0;; esac
  generation=$((generation + 1))
  tna_state_write_unlocked "$mode" "$state" "$owner" "$history" "$generation"
  flock -u 9
}
