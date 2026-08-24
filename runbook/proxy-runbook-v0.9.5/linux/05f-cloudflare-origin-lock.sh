#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

STATE_DIR="/etc/proxy-runbook/cloudflare"
STATE_FILE="$STATE_DIR/cidr-state.env"
V4_URL="https://www.cloudflare.com/ips-v4"
V6_URL="https://www.cloudflare.com/ips-v6"
ALLOW_MARKER="PNA-CF-XHTTP-V095-ALLOW"
DENY_MARKER="PNA-CF-XHTTP-V095-DENY"
MANAGED_MARKER="PNA-CF-XHTTP-V095"
MANAGED_PORT=8443

[ "$(id -u)" -eq 0 ] || { echo 'ERROR: run as root.' >&2; exit 1; }

state_value() {
  local key="$1" line
  [ -r "$STATE_FILE" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in "${key}="*) printf '%s\n' "${line#*=}"; return 0;; esac
  done < "$STATE_FILE"
  return 1
}

set_state_value() {
  local key="$1" value="$2" tmp
  install -d -m 755 "$STATE_DIR"
  tmp="$(mktemp "$STATE_DIR/.cidr-state.XXXXXX")"
  if [ -r "$STATE_FILE" ]; then
    awk -F= -v key="$key" '$1 != key {print}' "$STATE_FILE" > "$tmp"
  fi
  printf '%s=%s\n' "$key" "$value" >> "$tmp"
  chmod 644 "$tmp"
  mv -f -- "$tmp" "$STATE_FILE"
}

validate_cidrs() {
  local family="$1" file="$2" minimum="$3"
  python3 - "$family" "$file" "$minimum" <<'PY'
import ipaddress, pathlib, sys
family, path, minimum = int(sys.argv[1]), pathlib.Path(sys.argv[2]), int(sys.argv[3])
lines = [line.strip() for line in path.read_text(encoding="ascii").splitlines() if line.strip()]
if not minimum <= len(lines) <= 100:
    raise SystemExit(f"unexpected CIDR count: {len(lines)}")
if len(set(lines)) != len(lines):
    raise SystemExit("duplicate CIDR")
for line in lines:
    network = ipaddress.ip_network(line, strict=True)
    if network.version != family:
        raise SystemExit(f"wrong address family: {line}")
print(len(lines))
PY
}

fetch_lists() {
  local tmp v4 v6 count4 count6
  if [ "$(state_value CLOUDFLARE_FIREWALL_APPLIED || true)" = 1 ]; then
    echo 'PNA_CF_CIDR_ERROR=FIREWALL_ALREADY_APPLIED_REMOVE_BEFORE_REFRESH' >&2
    return 120
  fi
  command -v python3 >/dev/null 2>&1 || { echo 'PNA_CF_CIDR_ERROR=PYTHON3_MISSING' >&2; return 121; }
  tmp="$(mktemp -d /tmp/pna-cf-cidrs.XXXXXX)"
  v4="$tmp/ips-v4"
  v6="$tmp/ips-v6"
  if ! curl --fail --location --silent --show-error --retry 4 --connect-timeout 15 --max-time 60 --proto '=https' --tlsv1.2 --output "$v4" "$V4_URL" ||
     ! curl --fail --location --silent --show-error --retry 4 --connect-timeout 15 --max-time 60 --proto '=https' --tlsv1.2 --output "$v6" "$V6_URL"; then
    rm -rf -- "$tmp"
    echo 'PNA_CF_CIDR_ERROR=OFFICIAL_LIST_DOWNLOAD_FAILED' >&2
    return 121
  fi
  count4="$(validate_cidrs 4 "$v4" 10)" || { rm -rf -- "$tmp"; echo 'PNA_CF_CIDR_ERROR=IPV4_INVALID' >&2; return 122; }
  count6="$(validate_cidrs 6 "$v6" 5)" || { rm -rf -- "$tmp"; echo 'PNA_CF_CIDR_ERROR=IPV6_INVALID' >&2; return 122; }
  install -d -m 755 "$STATE_DIR"
  install -m 644 "$v4" "$STATE_DIR/ips-v4"
  install -m 644 "$v6" "$STATE_DIR/ips-v6"
  rm -rf -- "$tmp"
  {
    printf 'CLOUDFLARE_IPV4_COUNT=%s\n' "$count4"
    printf 'CLOUDFLARE_IPV6_COUNT=%s\n' "$count6"
    printf 'CLOUDFLARE_IPV4_SHA256=%s\n' "$(sha256sum "$STATE_DIR/ips-v4" | awk '{print $1}')"
    printf 'CLOUDFLARE_IPV6_SHA256=%s\n' "$(sha256sum "$STATE_DIR/ips-v6" | awk '{print $1}')"
    printf 'CLOUDFLARE_CIDR_FETCHED_AT=%s\n' "$(date -Is)"
    printf 'CLOUDFLARE_FIREWALL_APPLIED=0\n'
    printf 'CLOUDFLARE_FIREWALL_PORT=%s\n' "$MANAGED_PORT"
  } | install -m 644 /dev/stdin "$STATE_FILE"
  printf '__PNA_CF_CIDR_BEGIN__\n'
  cat "$STATE_FILE"
  printf 'CLOUDFLARE_API_MUTATION=NONE\n'
  printf '__PNA_CF_CIDR_END__\n'
}

ipv6_enabled() {
  grep -Eq '^[[:space:]]*IPV6[[:space:]]*=[[:space:]]*yes([[:space:]]|$)' /etc/default/ufw 2>/dev/null
}

managed_rule_numbers() {
  ufw status numbered 2>/dev/null | awk -v marker="$MANAGED_MARKER" '
    index($0, marker) {
      line=$0
      sub(/^\[[[:space:]]*/, "", line)
      sub(/\].*$/, "", line)
      if (line ~ /^[0-9]+$/) print line
    }'
}

remove_managed_rules() {
  local number loops=0
  command -v ufw >/dev/null 2>&1 || { echo 'PNA_CF_LOCK_ERROR=UFW_MISSING' >&2; return 124; }
  while :; do
    number="$(managed_rule_numbers | tail -n1 || true)"
    [ -n "$number" ] || break
    ufw --force delete "$number" >/dev/null
    loops=$((loops + 1))
    [ "$loops" -le 100 ] || { echo 'PNA_CF_LOCK_ERROR=RULE_REMOVAL_GUARD' >&2; return 125; }
  done
  [ -z "$(managed_rule_numbers || true)" ] || { echo 'PNA_CF_LOCK_ERROR=MANAGED_RULES_REMAIN' >&2; return 125; }
  set_state_value CLOUDFLARE_FIREWALL_APPLIED 0
  set_state_value CLOUDFLARE_FIREWALL_REMOVED_AT "$(date -Is)"
  printf '__PNA_CF_ORIGIN_LOCK_BEGIN__\n'
  printf 'CLOUDFLARE_FIREWALL_APPLIED=0\n'
  printf 'CLOUDFLARE_FIREWALL_PORT=%s\n' "$MANAGED_PORT"
  printf 'REALITY_443_POLICY=UNCHANGED\n'
  printf 'SSH_POLICY=UNCHANGED\n'
  printf '__PNA_CF_ORIGIN_LOCK_END__\n'
}

verify_rules() {
  local expected4 expected6 expected expected_deny total status allow_count deny_count
  # Cloudflare's official files may omit the final newline. `wc -l` would
  # undercount by one even though the apply loop correctly consumes the last
  # CIDR via `read ... || [ -n "$cidr" ]`.
  expected4="$(awk 'NF {count++} END {print count+0}' "$STATE_DIR/ips-v4")"
  expected6=0
  expected_deny=1
  if ipv6_enabled; then
    expected6="$(awk 'NF {count++} END {print count+0}' "$STATE_DIR/ips-v6")"
    expected_deny=2
  fi
  expected=$((expected4 + expected6))
  status="$(ufw status numbered)"
  allow_count="$(grep -cF "$ALLOW_MARKER" <<<"$status" || true)"
  deny_count="$(grep -cF "$DENY_MARKER" <<<"$status" || true)"
  [ "$allow_count" -eq "$expected" ] && [ "$deny_count" -eq "$expected_deny" ] || return 1
  total=$((expected + expected_deny))
  printf '%s\n' "$total"
}

apply_rules() {
  local cidr count ipv6_status
  command -v ufw >/dev/null 2>&1 || { echo 'PNA_CF_LOCK_ERROR=UFW_MISSING' >&2; return 124; }
  [ -s "$STATE_DIR/ips-v4" ] && [ -s "$STATE_DIR/ips-v6" ] || { echo 'PNA_CF_LOCK_ERROR=FETCH_FIRST' >&2; return 123; }
  ufw status 2>/dev/null | grep -q '^Status: active$' || { echo 'PNA_CF_LOCK_ERROR=UFW_INACTIVE' >&2; return 124; }
  ufw status verbose 2>/dev/null | grep -q '^Default: deny (incoming)' || { echo 'PNA_CF_LOCK_ERROR=DEFAULT_INCOMING_NOT_DENY' >&2; return 124; }
  if [ "$(state_value CLOUDFLARE_FIREWALL_APPLIED || true)" = 1 ] && count="$(verify_rules 2>/dev/null)"; then
    printf '__PNA_CF_ORIGIN_LOCK_BEGIN__\nCLOUDFLARE_FIREWALL_APPLIED=1\nCLOUDFLARE_FIREWALL_ALREADY_OPTIMAL=1\nMANAGED_RULE_COUNT=%s\nREALITY_443_POLICY=UNCHANGED\nSSH_POLICY=UNCHANGED\n__PNA_CF_ORIGIN_LOCK_END__\n' "$count"
    return 0
  fi
  remove_managed_rules >/dev/null 2>&1 || true
  # UFW 0.36.1 rejects `insert 1` for an IPv6 CIDR even though the same
  # syntax works for IPv4. `prepend` is supported for both families and
  # preserves the required ordering: the deny goes in first, then every
  # allow is prepended ahead of it.
  if ! ufw --force prepend deny "$MANAGED_PORT/tcp" comment "$DENY_MARKER" >/dev/null; then
    echo 'PNA_CF_LOCK_ERROR=DENY_INSERT_FAILED' >&2
    return 126
  fi
  while IFS= read -r cidr || [ -n "$cidr" ]; do
    [ -n "$cidr" ] || continue
    if ! ufw --force prepend allow proto tcp from "$cidr" to any port "$MANAGED_PORT" comment "$ALLOW_MARKER" >/dev/null; then
      remove_managed_rules >/dev/null 2>&1 || true
      echo 'PNA_CF_LOCK_ERROR=IPV4_ALLOW_INSERT_FAILED_ROLLED_BACK' >&2
      return 126
    fi
  done < "$STATE_DIR/ips-v4"
  ipv6_status=SKIPPED_UFW_IPV6_DISABLED
  if ipv6_enabled; then
    ipv6_status=ENABLED
    while IFS= read -r cidr || [ -n "$cidr" ]; do
      [ -n "$cidr" ] || continue
      if ! ufw --force prepend allow proto tcp from "$cidr" to any port "$MANAGED_PORT" comment "$ALLOW_MARKER" >/dev/null; then
        remove_managed_rules >/dev/null 2>&1 || true
        echo 'PNA_CF_LOCK_ERROR=IPV6_ALLOW_INSERT_FAILED_ROLLED_BACK' >&2
        return 126
      fi
    done < "$STATE_DIR/ips-v6"
  fi
  count="$(verify_rules)" || {
    remove_managed_rules >/dev/null 2>&1 || true
    echo 'PNA_CF_LOCK_ERROR=READBACK_FAILED_ROLLED_BACK' >&2
    return 127
  }
  set_state_value CLOUDFLARE_FIREWALL_APPLIED 1
  set_state_value CLOUDFLARE_FIREWALL_PORT "$MANAGED_PORT"
  set_state_value CLOUDFLARE_FIREWALL_APPLIED_AT "$(date -Is)"
  set_state_value CLOUDFLARE_IPV6_RULES "$ipv6_status"
  printf '__PNA_CF_ORIGIN_LOCK_BEGIN__\n'
  printf 'CLOUDFLARE_FIREWALL_APPLIED=1\n'
  printf 'CLOUDFLARE_FIREWALL_PORT=%s\n' "$MANAGED_PORT"
  printf 'MANAGED_RULE_COUNT=%s\n' "$count"
  printf 'ALLOWLIST_SOURCE=OFFICIAL_CLOUDFLARE_CIDRS\n'
  printf 'NON_CLOUDFLARE_8443=DENY\n'
  printf 'REALITY_443_POLICY=UNCHANGED\n'
  printf 'SSH_POLICY=UNCHANGED\n'
  printf '__PNA_CF_ORIGIN_LOCK_END__\n'
}

plan_rules() {
  [ -s "$STATE_DIR/ips-v4" ] && [ -s "$STATE_DIR/ips-v6" ] || { echo 'PNA_CF_CIDR_ERROR=FETCH_FIRST' >&2; return 123; }
  local ssh_port="${2:-22}"
  case "$ssh_port" in ''|*[!0-9]*) echo 'PNA_CF_CIDR_ERROR=SSH_PORT_INVALID' >&2; return 123;; esac
  printf '__PNA_CF_ORIGIN_LOCK_PLAN_BEGIN__\n'
  printf 'KEEP_SSH_PORT=%s\n' "$ssh_port"
  printf 'KEEP_REALITY_PUBLIC_TCP=443\n'
  printf 'ALLOW_FROM_CLOUDFLARE_TCP=8443\n'
  printf 'DENY_OTHER_SOURCES_TCP=8443\n'
  printf 'CLOUDFLARE_FIREWALL_APPLIED=%s\n' "$(state_value CLOUDFLARE_FIREWALL_APPLIED || printf 0)"
  printf 'PLAN_ONLY=1\n'
  printf '__PNA_CF_ORIGIN_LOCK_PLAN_END__\n'
}

show_status() {
  printf '__PNA_CF_ORIGIN_LOCK_BEGIN__\n'
  printf 'CLOUDFLARE_FIREWALL_APPLIED=%s\n' "$(state_value CLOUDFLARE_FIREWALL_APPLIED || printf 0)"
  printf 'CLOUDFLARE_FIREWALL_PORT=%s\n' "$MANAGED_PORT"
  printf 'MANAGED_RULE_COUNT=%s\n' "$(managed_rule_numbers | wc -l | tr -d ' ')"
  printf 'REALITY_443_POLICY=UNCHANGED\n'
  printf 'SSH_POLICY=UNCHANGED\n'
  printf '__PNA_CF_ORIGIN_LOCK_END__\n'
}

case "${1:-}" in
  fetch) [ "$#" -eq 1 ] || exit 2; fetch_lists ;;
  plan) [ "$#" -le 2 ] || exit 2; plan_rules plan "${2:-22}" ;;
  apply) [ "$#" -eq 1 ] || exit 2; apply_rules ;;
  remove) [ "$#" -eq 1 ] || exit 2; remove_managed_rules ;;
  status) [ "$#" -eq 1 ] || exit 2; show_status ;;
  *) echo 'usage: 05f-cloudflare-origin-lock.sh fetch | plan [SSH_PORT] | apply | remove | status' >&2; exit 2 ;;
esac
