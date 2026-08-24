#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
STATE_DIR="/etc/proxy-runbook"
STATE_FILE="$STATE_DIR/ip-rebind-public.env"
IDENTITY_FILE="$STATE_DIR/node-identity.env"
PUBLIC_FILE="$STATE_DIR/public.env"
DEPLOYMENT_FILE="$STATE_DIR/deployment-state.env"
LOCK_FILE="/run/lock/proxy-node-assistant-ip-rebind.lock"
AUDIT_FILE="$STATE_DIR/ip-rebind-audit.log"

die() {
  printf 'PNA_IP_REBIND_ERROR=%s\n' "$1" >&2
  exit "${2:-1}"
}

value_from() {
  local file="$1" key="$2" line
  [ -r "$file" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in "${key}="*) printf '%s\n' "${line#*=}"; return 0;; esac
  done < "$file"
  return 1
}

valid_public_ipv4() {
  python3 - "$1" <<'PY' >/dev/null 2>&1
import ipaddress,sys
try:
    value=ipaddress.ip_address(sys.argv[1])
except ValueError:
    raise SystemExit(1)
raise SystemExit(0 if value.version == 4 and value.is_global else 1)
PY
}

valid_domain() {
  [[ "$1" =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$ ]]
}

public_ipv4() {
  local candidate
  candidate="$(curl -4fsS --max-time 10 https://api.ipify.org 2>/dev/null || true)"
  valid_public_ipv4 "$candidate" || die REMOTE_PUBLIC_IPV4_UNAVAILABLE 61
  printf '%s\n' "$candidate"
}

require_identity() {
  [ -s "$IDENTITY_FILE" ] || die NODE_IDENTITY_MISSING 62
  bash "$ROOT/linux/23-node-identity.sh" --show >/dev/null || die NODE_IDENTITY_INVALID 62
}

identity_value() {
  value_from "$IDENTITY_FILE" "$1"
}

deployment_value() {
  value_from "$DEPLOYMENT_FILE" "$1"
}

write_state() {
  local status="$1" old_ip="$2" new_ip="$3" old_domain="$4" new_domain="$5" snapshot="$6"
  local dns_phase="${7:-PRE_DNS}" tmp
  install -d -m 700 "$STATE_DIR"
  tmp="$(mktemp "$STATE_DIR/.ip-rebind.XXXXXX")"
  {
    echo 'IP_REBIND_STATE_VERSION=1'
    printf 'IP_REBIND_STATUS=%s\n' "$status"
    printf 'OLD_IP=%s\nNEW_IP=%s\n' "$old_ip" "$new_ip"
    printf 'OLD_CONSTRUCTION_DOMAIN=%s\nNEW_CONSTRUCTION_DOMAIN=%s\n' "$old_domain" "$new_domain"
    printf 'DOMAIN_CHANGED=%s\n' "$([ "$old_domain" = "$new_domain" ] && printf false || printf true)"
    printf 'SERVER_ID=%s\nNODE_ID=%s\n' "$(identity_value SERVER_ID)" "$(identity_value NODE_ID)"
    printf 'MACHINE_ID_SHA256=%s\nSSH_HOST_KEY_SHA256=%s\n' "$(identity_value MACHINE_ID_SHA256)" "$(identity_value SSH_HOST_KEY_SHA256)"
    printf 'DEPLOYMENT_MODE=%s\nACTIVE_MODE=%s\n' "$(deployment_value DEPLOYMENT_MODE || printf direct-reality)" "$(deployment_value ACTIVE_MODE || printf ACTIVE_DIRECT)"
    printf 'DNS_PHASE=%s\nSNAPSHOT=%s\n' "$dns_phase" "$snapshot"
    printf 'UPDATED_AT=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  } > "$tmp"
  chmod 600 "$tmp"
  mv -f -- "$tmp" "$STATE_FILE"
}

append_audit() {
  install -d -m 700 "$STATE_DIR"
  touch "$AUDIT_FILE"
  chmod 600 "$AUDIT_FILE"
  printf '%s status=%s old_sha256=%s new_sha256=%s\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" \
    "$(printf '%s' "$2" | sha256sum | awk '{print $1}')" \
    "$(printf '%s' "$3" | sha256sum | awk '{print $1}')" >> "$AUDIT_FILE"
}

managed_reference_count() {
  local old_ip="$1" count=0 file
  for file in "$PUBLIC_FILE" "$IDENTITY_FILE" "$DEPLOYMENT_FILE" \
    /etc/proxy-runbook/cdn-xhttp.env /etc/proxy-runbook/private-drive.env \
    /etc/nginx/conf.d/proxy-node-assistant*.conf /etc/nginx/sites-enabled/proxy-node-assistant*; do
    [ -f "$file" ] || continue
    if grep -Fq -- "$old_ip" "$file" 2>/dev/null; then
      count=$((count + 1))
    fi
  done
  printf '%s\n' "$count"
}

unmanaged_reference_count() {
  local old_ip="$1" count=0
  while IFS= read -r file; do
    case "$file" in
      /etc/proxy-runbook/*|/etc/nginx/conf.d/proxy-node-assistant*|/etc/nginx/sites-enabled/proxy-node-assistant*) continue;;
    esac
    count=$((count + 1))
  done < <(grep -RIlF --exclude='*.log' --exclude='*.gz' -- "$old_ip" /etc/systemd/system /etc/nginx 2>/dev/null | sed -n '1,100p')
  printf '%s\n' "$count"
}

create_snapshot() {
  local stamp dir archive
  stamp="$(date -u +%Y%m%d-%H%M%S)"
  dir="/root/proxy-node-ip-rebind-${stamp}"
  archive="${dir}.tar.gz"
  install -d -m 700 "$dir"
  for path in /etc/proxy-runbook /etc/x-ui /etc/nginx /etc/letsencrypt /etc/ufw /etc/fail2ban; do
    [ -e "$path" ] && (cd / && cp -a --parents "${path#/}" "$dir/")
  done
  ss -lntup > "$dir/listeners.txt" 2>&1 || true
  systemctl is-active x-ui nginx > "$dir/services.txt" 2>&1 || true
  tar -C /root -czf "$archive" "$(basename "$dir")"
  chmod 600 "$archive"
  case "$dir" in
    /root/proxy-node-ip-rebind-[0-9]*) ;;
    *) die SNAPSHOT_PATH_INVALID 63 ;;
  esac
  rm -rf -- "$dir"
  tar -tzf "$archive" >/dev/null || die SNAPSHOT_VERIFY_FAILED 63
  printf '%s\n' "$archive"
}

preflight() {
  [ "$#" -eq 4 ] || die USAGE 2
  local old_ip="$1" new_ip="$2" old_domain="$3" new_domain="$4"
  local current_public recorded_public mode active snapshot managed unmanaged
  valid_public_ipv4 "$old_ip" || die OLD_IP_INVALID 64
  valid_public_ipv4 "$new_ip" || die NEW_IP_INVALID 64
  [ "$old_ip" != "$new_ip" ] || die NEW_IP_EQUALS_OLD_IP 64
  valid_domain "$old_domain" || die OLD_DOMAIN_INVALID 64
  valid_domain "$new_domain" || die NEW_DOMAIN_INVALID 64
  require_identity
  [ "$(identity_value CURRENT_PUBLIC_IP)" = "$old_ip" ] || die IDENTITY_OLD_IP_MISMATCH 65
  recorded_public="$(value_from "$PUBLIC_FILE" PUBLIC_IP || true)"
  [ "$recorded_public" = "$old_ip" ] || die RUNTIME_OLD_IP_MISMATCH 65
  current_public="$(public_ipv4)"
  [ "$current_public" = "$new_ip" ] || die REMOTE_PUBLIC_IP_MISMATCH 66
  systemctl is-active --quiet x-ui || die X_UI_INACTIVE 67
  systemctl is-active --quiet nginx || die NGINX_INACTIVE 67
  nginx -t >/dev/null 2>&1 || die NGINX_CONFIG_INVALID 67
  ss -lntH | awk '$4 ~ /:443$/ {ok=1} END{exit !ok}' || die PORT_443_LISTENER_MISSING 67
  curl -fsS --max-time 8 http://127.0.0.1:8443/ >/dev/null || die COVER_LOOPBACK_FAILED 67
  mode="$(deployment_value DEPLOYMENT_MODE || printf direct-reality)"
  active="$(deployment_value ACTIVE_MODE || printf ACTIVE_DIRECT)"
  case "$mode:$active" in
    direct-reality:ACTIVE_DIRECT|dual-hot-switch:DUAL_INSTALLED_ACTIVE_DIRECT|cdn-xhttp-tls:ACTIVE_CDN|dual-hot-switch:DUAL_INSTALLED_ACTIVE_CDN) ;;
    *) die DEPLOYMENT_STATE_NOT_REBINDABLE 68;;
  esac
  snapshot="$(create_snapshot)"
  managed="$(managed_reference_count "$old_ip")"
  unmanaged="$(unmanaged_reference_count "$old_ip")"
  write_state IP_REBIND_PREPARED "$old_ip" "$new_ip" "$old_domain" "$new_domain" "$snapshot" PRE_DNS
  append_audit PREPARED "$old_ip" "$new_ip"
  echo '__PNA_IP_REBIND_PREFLIGHT_V1_BEGIN__'
  printf 'IP_REBIND_STATUS=IP_REBIND_PREPARED\nOLD_IP=%s\nNEW_IP=%s\n' "$old_ip" "$new_ip"
  printf 'OLD_CONSTRUCTION_DOMAIN=%s\nNEW_CONSTRUCTION_DOMAIN=%s\n' "$old_domain" "$new_domain"
  printf 'DOMAIN_CHANGED=%s\n' "$([ "$old_domain" = "$new_domain" ] && printf false || printf true)"
  printf 'SERVER_ID_MATCH=1\nNODE_ID_UNCHANGED=1\nMACHINE_ID_MATCH=1\nREMOTE_PUBLIC_IP_MATCH=1\n'
  printf 'DEPLOYMENT_MODE=%s\nACTIVE_MODE=%s\n' "$mode" "$active"
  printf 'MANAGED_OLD_IP_REFERENCE_COUNT=%s\nUNMANAGED_OLD_IP_REFERENCE_COUNT=%s\n' "$managed" "$unmanaged"
  printf 'SNAPSHOT_CREATED=1\nDNS_MUTATED=0\nCLOUDFLARE_MUTATION=NONE\n'
  echo '__PNA_IP_REBIND_PREFLIGHT_V1_END__'
}

dns_direct_matches() {
  local domain="$1" new_ip="$2" addresses
  addresses="$(getent ahostsv4 "$domain" 2>/dev/null | awk '{print $1}' | sort -u)"
  [ -n "$addresses" ] || return 1
  [ "$(printf '%s\n' "$addresses" | grep -Fvx -- "$new_ip" | wc -l)" -eq 0 ]
}

replace_env_value() {
  local file="$1" key="$2" replacement="$3" tmp
  [ -f "$file" ] || return 1
  tmp="$(mktemp "$(dirname "$file")/.rebind-env.XXXXXX")"
  awk -v key="$key" -v replacement="$replacement" '
    BEGIN { done=0 }
    index($0,key "=")==1 { print key "=" replacement; done=1; next }
    { print }
    END { if (!done) print key "=" replacement }
  ' "$file" > "$tmp"
  chmod --reference="$file" "$tmp" 2>/dev/null || chmod 600 "$tmp"
  chown --reference="$file" "$tmp" 2>/dev/null || true
  mv -f -- "$tmp" "$file"
}

commit_direct() {
  [ "$#" -eq 4 ] || die USAGE 2
  local old_ip="$1" new_ip="$2" old_domain="$3" new_domain="$4" status mode active snapshot
  [ -s "$STATE_FILE" ] || die PREPARED_STATE_MISSING 69
  status="$(value_from "$STATE_FILE" IP_REBIND_STATUS || true)"
  [ "$status" = IP_REBIND_PREPARED ] || die PREPARED_STATE_INVALID 69
  [ "$(value_from "$STATE_FILE" OLD_IP)" = "$old_ip" ] || die PREPARED_OLD_IP_MISMATCH 69
  [ "$(value_from "$STATE_FILE" NEW_IP)" = "$new_ip" ] || die PREPARED_NEW_IP_MISMATCH 69
  [ "$(value_from "$STATE_FILE" OLD_CONSTRUCTION_DOMAIN)" = "$old_domain" ] || die PREPARED_OLD_DOMAIN_MISMATCH 69
  [ "$(value_from "$STATE_FILE" NEW_CONSTRUCTION_DOMAIN)" = "$new_domain" ] || die PREPARED_NEW_DOMAIN_MISMATCH 69
  [ "$old_domain" = "$new_domain" ] || die JOINT_DOMAIN_MIGRATION_REQUIRES_CLOUDFLARE_PHASE 70
  mode="$(value_from "$STATE_FILE" DEPLOYMENT_MODE)"
  active="$(value_from "$STATE_FILE" ACTIVE_MODE)"
  case "$mode:$active" in direct-reality:ACTIVE_DIRECT|dual-hot-switch:DUAL_INSTALLED_ACTIVE_DIRECT) ;;
    *) die DIRECT_COMMIT_NOT_ALLOWED_FOR_ACTIVE_MODE 70;;
  esac
  [ "$(public_ipv4)" = "$new_ip" ] || die REMOTE_PUBLIC_IP_MISMATCH 66
  dns_direct_matches "$new_domain" "$new_ip" || die DIRECT_DNS_NOT_CONVERGED 71
  snapshot="$(value_from "$STATE_FILE" SNAPSHOT)"

  # DNS is already external and cannot safely be rolled back to an address the
  # provider may have reclaimed. From this point failures are POST_DNS and all
  # managed state stays directed at the verified new address for repair.
  write_state IP_REBIND_COMMITTING "$old_ip" "$new_ip" "$old_domain" "$new_domain" "$snapshot" POST_DNS
  replace_env_value "$PUBLIC_FILE" PUBLIC_IP "$new_ip" || die PUBLIC_ENV_UPDATE_FAILED 72
  replace_env_value "$IDENTITY_FILE" CURRENT_PUBLIC_IP "$new_ip" || die IDENTITY_IP_UPDATE_FAILED 72
  if ! bash "$ROOT/linux/04a-reality-api.sh" normalize-share "$new_ip" >/dev/null; then
    write_state IP_REBIND_BLOCKED_POST_DNS "$old_ip" "$new_ip" "$old_domain" "$new_domain" "$snapshot" POST_DNS
    append_audit BLOCKED_POST_DNS "$old_ip" "$new_ip"
    die REALITY_SHARE_ADDRESS_UPDATE_FAILED 73
  fi
  if ! bash "$ROOT/linux/04a-reality-api.sh" inspect-443 "$new_domain" "$new_ip" >/dev/null || \
     ! systemctl is-active --quiet x-ui || ! nginx -t >/dev/null 2>&1; then
    write_state IP_REBIND_BLOCKED_POST_DNS "$old_ip" "$new_ip" "$old_domain" "$new_domain" "$snapshot" POST_DNS
    append_audit BLOCKED_POST_DNS "$old_ip" "$new_ip"
    die POST_DNS_HEALTH_CHECK_FAILED 74
  fi
  write_state IP_REBIND_COMPLETE "$old_ip" "$new_ip" "$old_domain" "$new_domain" "$snapshot" POST_DNS
  append_audit COMPLETE "$old_ip" "$new_ip"
  echo '__PNA_IP_REBIND_COMMIT_V1_BEGIN__'
  printf 'IP_REBIND_STATUS=IP_REBIND_COMPLETE\nOLD_IP=%s\nNEW_IP=%s\n' "$old_ip" "$new_ip"
  printf 'SERVER_ID_MATCH=1\nNODE_ID_UNCHANGED=1\nMACHINE_ID_MATCH=1\nREMOTE_PUBLIC_IP_MATCH=1\n'
  printf 'CLOUDFLARE_RECORD_CONTENT_MATCH=NOT_APPLICABLE_DIRECT\nCLOUDFLARE_PROXIED_MATCH=DNS_ONLY\n'
  printf 'ZONE_ORIGIN_LEAK_SCAN=NOT_APPLICABLE_DIRECT\nCURRENT_ORIGIN_CONCEALED=false\n'
  printf 'CLIENT_LINK_CHANGED=false\nSSH_AUTH_KEY_ROTATED=0\n'
  echo '__PNA_IP_REBIND_COMMIT_V1_END__'
}

wait_cloudflare() {
  [ "$#" -eq 4 ] || die USAGE 2
  local old_ip="$1" new_ip="$2" old_domain="$3" new_domain="$4" snapshot
  [ -s "$STATE_FILE" ] || die PREPARED_STATE_MISSING 69
  [ "$(value_from "$STATE_FILE" IP_REBIND_STATUS)" = IP_REBIND_PREPARED ] || die PREPARED_STATE_INVALID 69
  [ "$(value_from "$STATE_FILE" NEW_IP)" = "$new_ip" ] || die PREPARED_NEW_IP_MISMATCH 69
  snapshot="$(value_from "$STATE_FILE" SNAPSHOT)"
  write_state WAITING_FOR_CLOUDFLARE_MANUAL_ACTION "$old_ip" "$new_ip" "$old_domain" "$new_domain" "$snapshot" PRE_DNS
  append_audit WAITING_CLOUDFLARE "$old_ip" "$new_ip"
  echo '__PNA_IP_REBIND_WAIT_V1_BEGIN__'
  echo 'IP_REBIND_STATUS=WAITING_FOR_CLOUDFLARE_MANUAL_ACTION'
  printf 'OLD_IP=%s\nNEW_IP=%s\nOLD_CONSTRUCTION_DOMAIN=%s\nNEW_CONSTRUCTION_DOMAIN=%s\n' "$old_ip" "$new_ip" "$old_domain" "$new_domain"
  echo 'CLOUDFLARE_MUTATION=NONE'
  echo 'EXPECTED_PROXY_STATE=PROXIED'
  echo 'ZONE_ORIGIN_LEAK_SCAN=NOT_VERIFIED'
  echo 'PRODUCTION_443_PROMOTION=BLOCKED'
  echo '__PNA_IP_REBIND_WAIT_V1_END__'
}

abort_pre_dns() {
  [ -s "$STATE_FILE" ] || { echo 'IP_REBIND_ABORT_NOT_NEEDED'; return; }
  [ "$(value_from "$STATE_FILE" DNS_PHASE || true)" = PRE_DNS ] || die POST_DNS_ABORT_REFUSED 75
  local old_ip new_ip old_domain new_domain snapshot
  old_ip="$(value_from "$STATE_FILE" OLD_IP)"; new_ip="$(value_from "$STATE_FILE" NEW_IP)"
  old_domain="$(value_from "$STATE_FILE" OLD_CONSTRUCTION_DOMAIN)"; new_domain="$(value_from "$STATE_FILE" NEW_CONSTRUCTION_DOMAIN)"
  snapshot="$(value_from "$STATE_FILE" SNAPSHOT || true)"
  write_state IP_REBIND_ABORTED_PRE_DNS "$old_ip" "$new_ip" "$old_domain" "$new_domain" "$snapshot" PRE_DNS
  append_audit ABORTED_PRE_DNS "$old_ip" "$new_ip"
  echo 'IP_REBIND_ABORTED_PRE_DNS'
}

show_status() {
  if [ ! -s "$STATE_FILE" ]; then
    echo '__PNA_IP_REBIND_STATUS_V1_BEGIN__'
    echo 'IP_REBIND_STATUS=IDLE'
    echo '__PNA_IP_REBIND_STATUS_V1_END__'
    return
  fi
  echo '__PNA_IP_REBIND_STATUS_V1_BEGIN__'
  grep -E '^(IP_REBIND_STATUS|OLD_IP|NEW_IP|OLD_CONSTRUCTION_DOMAIN|NEW_CONSTRUCTION_DOMAIN|DOMAIN_CHANGED|DEPLOYMENT_MODE|ACTIVE_MODE|DNS_PHASE|UPDATED_AT)=' "$STATE_FILE"
  echo '__PNA_IP_REBIND_STATUS_V1_END__'
}

[ "$(id -u)" -eq 0 ] || die ROOT_REQUIRED 2
command -v flock >/dev/null 2>&1 || die FLOCK_MISSING 2
install -d -m 755 "$(dirname "$LOCK_FILE")"
exec 9>"$LOCK_FILE"
flock -x 9

case "${1:-status}" in
  status|--status) show_status ;;
  preflight) shift; preflight "$@" ;;
  commit-direct) shift; commit_direct "$@" ;;
  wait-cloudflare) shift; wait_cloudflare "$@" ;;
  abort-pre-dns) abort_pre_dns ;;
  *) die USAGE 2 ;;
esac
