#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

STATE_DIR="/etc/proxy-runbook/cloudflare"
V4_URL="https://www.cloudflare.com/ips-v4"
V6_URL="https://www.cloudflare.com/ips-v6"

[ "$(id -u)" -eq 0 ] || { echo 'ERROR: run as root.' >&2; exit 1; }

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
  command -v python3 >/dev/null 2>&1 || { echo 'PNA_CF_CIDR_ERROR=PYTHON3_MISSING' >&2; return 121; }
  tmp="$(mktemp -d /tmp/pna-cf-cidrs.XXXXXX)"
  trap 'rm -rf -- "$tmp"' RETURN
  v4="$tmp/ips-v4"
  v6="$tmp/ips-v6"
  curl --fail --location --silent --show-error --retry 4 --connect-timeout 15 --max-time 60 --proto '=https' --tlsv1.2 --output "$v4" "$V4_URL"
  curl --fail --location --silent --show-error --retry 4 --connect-timeout 15 --max-time 60 --proto '=https' --tlsv1.2 --output "$v6" "$V6_URL"
  count4="$(validate_cidrs 4 "$v4" 10)" || { echo 'PNA_CF_CIDR_ERROR=IPV4_INVALID' >&2; return 122; }
  count6="$(validate_cidrs 6 "$v6" 5)" || { echo 'PNA_CF_CIDR_ERROR=IPV6_INVALID' >&2; return 122; }
  install -d -m 755 "$STATE_DIR"
  install -m 644 "$v4" "$STATE_DIR/ips-v4"
  install -m 644 "$v6" "$STATE_DIR/ips-v6"
  {
    printf 'CLOUDFLARE_IPV4_COUNT=%s\n' "$count4"
    printf 'CLOUDFLARE_IPV6_COUNT=%s\n' "$count6"
    printf 'CLOUDFLARE_IPV4_SHA256=%s\n' "$(sha256sum "$v4" | awk '{print $1}')"
    printf 'CLOUDFLARE_IPV6_SHA256=%s\n' "$(sha256sum "$v6" | awk '{print $1}')"
    printf 'CLOUDFLARE_CIDR_FETCHED_AT=%s\n' "$(date -Is)"
    printf 'CLOUDFLARE_FIREWALL_APPLIED=0\n'
  } | install -m 644 /dev/stdin "$STATE_DIR/cidr-state.env"
  printf '__PNA_CF_CIDR_BEGIN__\n'
  cat "$STATE_DIR/cidr-state.env"
  printf 'CLOUDFLARE_MUTATION=NONE\n'
  printf '__PNA_CF_CIDR_END__\n'
}

plan_rules() {
  [ -s "$STATE_DIR/ips-v4" ] && [ -s "$STATE_DIR/ips-v6" ] || { echo 'PNA_CF_CIDR_ERROR=FETCH_FIRST' >&2; return 123; }
  local ssh_port="${2:-22}"
  case "$ssh_port" in ''|*[!0-9]*) echo 'PNA_CF_CIDR_ERROR=SSH_PORT_INVALID' >&2; return 123;; esac
  printf '__PNA_CF_ORIGIN_LOCK_PLAN_BEGIN__\n'
  printf 'KEEP_SSH_PORT=%s\n' "$ssh_port"
  printf 'ALLOW_FROM_CLOUDFLARE_TCP=80,443,8443\n'
  printf 'DENY_OTHER_SOURCES_TCP=80,443,8443\n'
  printf 'REMOVE_WIDE_ALLOW_ONLY_AFTER_SECOND_SSH_AND_EDGE_PROBE=1\n'
  printf 'CLOUDFLARE_FIREWALL_APPLIED=0\n'
  printf 'PLAN_ONLY=1\n'
  printf '__PNA_CF_ORIGIN_LOCK_PLAN_END__\n'
}

case "${1:-}" in
  fetch) [ "$#" -eq 1 ] || exit 2; fetch_lists ;;
  plan) [ "$#" -le 2 ] || exit 2; plan_rules plan "${2:-22}" ;;
  *) echo 'usage: 05f-cloudflare-origin-lock.sh fetch | plan [SSH_PORT]' >&2; exit 2 ;;
esac
