#!/usr/bin/env bash

# Lean route state for the v0.9.0-based v0.9.5 reset.  This file deliberately
# models routes only; unrelated legacy subsystems are intentionally absent.
TNA_DEPLOYMENT_STATE_FILE="${TNA_DEPLOYMENT_STATE_FILE:-/etc/text-node-assistant/deployment-state.env}"
TNA_DEPLOYMENT_LOCK_FILE="${TNA_DEPLOYMENT_LOCK_FILE:-/run/lock/text-node-assistant-deployment.lock}"

tna_valid_route_mode() {
  case "${1:-}" in managed-gray|managed-orange|managed-dual) return 0;; *) return 1;; esac
}

tna_valid_route_phase() {
  case "${1:-}" in staging|waiting-for-edge|active) return 0;; *) return 1;; esac
}

tna_valid_reality_owner() {
  case "${1:-}" in xray-reality|none) return 0;; *) return 1;; esac
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
  local mode="${1:?mode required}" phase="${2:?phase required}" owner="${3:?owner required}"
  local generation="${4:-1}" dir tmp
  tna_valid_route_mode "$mode" || return 81
  tna_valid_route_phase "$phase" || return 81
  tna_valid_reality_owner "$owner" || return 81
  case "$generation" in ''|*[!0-9]*) return 81;; esac
  [ "$mode" != managed-gray ] || [ "$phase" = active ] || return 81
  [ "$mode" != managed-orange ] || [ "$owner" = none ] || return 81
  [ "$mode" != managed-dual ] || [ "$owner" = xray-reality ] || return 81
  dir="$(dirname "$TNA_DEPLOYMENT_STATE_FILE")"
  install -d -m 755 "$dir"
  tmp="$(mktemp "${dir}/.deployment-state.XXXXXX")"
  {
    printf 'TNA_STATE_VERSION=2\n'
    printf 'ROUTE_MODE=%s\n' "$mode"
    printf 'ROUTE_PHASE=%s\n' "$phase"
    printf 'REALITY_443_OWNER=%s\n' "$owner"
    printf 'CDN_EDGE_PORT=8443\n'
    printf 'CDN_ORIGIN_PORT=8443\n'
    printf 'STATE_GENERATION=%s\n' "$generation"
    printf 'STATE_UPDATED_AT=%s\n' "$(date -Is)"
  } > "$tmp"
  chmod 644 "$tmp"
  mv -f -- "$tmp" "$TNA_DEPLOYMENT_STATE_FILE"
}

tna_state_commit_route() {
  local mode="${1:?mode required}" phase="${2:?phase required}" owner="${3:?owner required}"
  local generation
  command -v flock >/dev/null 2>&1 || { echo 'TNA_STATE_ERROR=FLOCK_MISSING' >&2; return 82; }
  install -d -m 755 "$(dirname "$TNA_DEPLOYMENT_LOCK_FILE")"
  exec 9>"$TNA_DEPLOYMENT_LOCK_FILE"
  flock -x 9
  generation="$(tna_state_env_value STATE_GENERATION || true)"
  case "$generation" in ''|*[!0-9]*) generation=0;; esac
  generation=$((generation + 1))
  tna_state_write_unlocked "$mode" "$phase" "$owner" "$generation"
  flock -u 9
}

tna_state_init_gray_if_missing() {
  [ -s "$TNA_DEPLOYMENT_STATE_FILE" ] && return 0
  tna_state_commit_route managed-gray active xray-reality
}

tna_state_show() {
  local mode phase owner generation
  [ -r "$TNA_DEPLOYMENT_STATE_FILE" ] || { echo 'TNA_STATE_ERROR=MISSING' >&2; return 83; }
  mode="$(tna_state_env_value ROUTE_MODE || true)"
  phase="$(tna_state_env_value ROUTE_PHASE || true)"
  owner="$(tna_state_env_value REALITY_443_OWNER || true)"
  generation="$(tna_state_env_value STATE_GENERATION || true)"
  tna_valid_route_mode "$mode" && tna_valid_route_phase "$phase" && tna_valid_reality_owner "$owner" || {
    echo 'TNA_STATE_ERROR=INVALID' >&2; return 84;
  }
  printf '__TNA_DEPLOYMENT_STATE_BEGIN__\n'
  printf 'ROUTE_MODE=%s\nROUTE_PHASE=%s\nREALITY_443_OWNER=%s\nCDN_EDGE_PORT=8443\nCDN_ORIGIN_PORT=8443\nSTATE_GENERATION=%s\n' \
    "$mode" "$phase" "$owner" "$generation"
  printf '__TNA_DEPLOYMENT_STATE_END__\n'
}
