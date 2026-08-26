#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

MODE="${1:---show}"
STATE_DIR="/etc/text-node-assistant"
STATE_FILE="$STATE_DIR/node-identity.env"

die() {
  printf 'TNA_NODE_IDENTITY_ERROR=%s\n' "$1" >&2
  exit "${2:-1}"
}

machine_hash() {
  [ -s /etc/machine-id ] || die MACHINE_ID_MISSING 51
  sha256sum /etc/machine-id | awk '{print $1}'
}

host_key_metadata() {
  local public algorithm fingerprint
  if [ -s /etc/ssh/ssh_host_ed25519_key.pub ]; then
    public=/etc/ssh/ssh_host_ed25519_key.pub
  elif [ -s /etc/ssh/ssh_host_ecdsa_key.pub ]; then
    public=/etc/ssh/ssh_host_ecdsa_key.pub
  elif [ -s /etc/ssh/ssh_host_rsa_key.pub ]; then
    public=/etc/ssh/ssh_host_rsa_key.pub
  else
    die SSH_HOST_PUBLIC_KEY_MISSING 52
  fi
  algorithm="$(awk '{print $1}' "$public")"
  fingerprint="$(ssh-keygen -E sha256 -lf "$public" | awk '{print $2}')"
  [[ "$algorithm" =~ ^ssh-(ed25519|rsa)$|^ecdsa-sha2-nistp(256|384|521)$ ]] || die SSH_HOST_ALGORITHM_INVALID 52
  [[ "$fingerprint" =~ ^SHA256:[A-Za-z0-9+/]+$ ]] || die SSH_HOST_FINGERPRINT_INVALID 52
  printf '%s\t%s\n' "$algorithm" "$fingerprint"
}

public_ipv4() {
  local value
  value="$(curl -4fsS --max-time 10 https://api.ipify.org 2>/dev/null || true)"
  if ! python3 - "$value" <<'PY' >/dev/null 2>&1
import ipaddress,sys
value=ipaddress.ip_address(sys.argv[1])
raise SystemExit(0 if value.version == 4 and value.is_global else 1)
PY
  then
    die PUBLIC_IPV4_UNAVAILABLE 53
  fi
  printf '%s' "$value"
}

value() {
  local key="$1"
  sed -n "s/^${key}=//p" "$STATE_FILE" 2>/dev/null | sed -n '1p'
}

validate_state() {
  [ -s "$STATE_FILE" ] || die STATE_MISSING 54
  [ "$(value IDENTITY_VERSION)" = 1 ] || die STATE_VERSION_INVALID 54
  # Preserve the exact stable identity created by public ProxyNodeAssistant
  # v0.9.5 builds. Renaming the product must not silently mint a new server or
  # node identity and break bound keys, device admission, or dismantle receipts.
  # New installs still create tna-* values below; pna-* is accepted only as a
  # backward-compatible persisted identity.
  [[ "$(value SERVER_ID)" =~ ^(tna|pna)-srv-[0-9a-f]{32}$ ]] || die SERVER_ID_INVALID 54
  [[ "$(value NODE_ID)" =~ ^(tna|pna)-node-[0-9a-f]{32}$ ]] || die NODE_ID_INVALID 54
  [[ "$(value MACHINE_ID_SHA256)" =~ ^[0-9a-f]{64}$ ]] || die MACHINE_ID_HASH_INVALID 54
  [ "$(value MACHINE_ID_SHA256)" = "$(machine_hash)" ] || die MACHINE_ID_MISMATCH 55
  [[ "$(value FIRST_KNOWN_PUBLIC_IP)" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || die FIRST_IP_INVALID 54
  [[ "$(value CURRENT_PUBLIC_IP)" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || die CURRENT_IP_INVALID 54
  [[ "$(value SSH_HOST_KEY_SHA256)" =~ ^SHA256:[A-Za-z0-9+/]+$ ]] || die HOST_KEY_STATE_INVALID 54
}

init_state() {
  [ "$(id -u)" -eq 0 ] || die ROOT_REQUIRED 2
  if [ -s "$STATE_FILE" ]; then
    validate_state
    show_state
    echo 'TNA_NODE_IDENTITY_ALREADY_INITIALIZED'
    return
  fi
  local machine public host algorithm fingerprint tmp
  machine="$(machine_hash)"
  public="$(public_ipv4)"
  host="$(host_key_metadata)"
  algorithm="${host%%$'\t'*}"
  fingerprint="${host#*$'\t'}"
  install -d -m 700 "$STATE_DIR"
  tmp="$(mktemp "$STATE_DIR/.node-identity.XXXXXX")"
  {
    echo 'IDENTITY_VERSION=1'
    printf 'SERVER_ID=tna-srv-%s\n' "$(openssl rand -hex 16)"
    printf 'NODE_ID=tna-node-%s\n' "$(openssl rand -hex 16)"
    printf 'MACHINE_ID_SHA256=%s\n' "$machine"
    printf 'SSH_HOST_KEY_ALGORITHM=%s\n' "$algorithm"
    printf 'SSH_HOST_KEY_SHA256=%s\n' "$fingerprint"
    echo 'SSH_AUTH_KEY_ID=CLIENT_SIDE'
    printf 'FIRST_KNOWN_PUBLIC_IP=%s\n' "$public"
    printf 'CURRENT_PUBLIC_IP=%s\n' "$public"
    printf 'CREATED_AT=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  } > "$tmp"
  chmod 600 "$tmp"
  mv -f -- "$tmp" "$STATE_FILE"
  validate_state
  show_state
  echo 'TNA_NODE_IDENTITY_INITIALIZED'
}

show_state() {
  validate_state
  local host current_algorithm current_fingerprint
  host="$(host_key_metadata)"
  current_algorithm="${host%%$'\t'*}"
  current_fingerprint="${host#*$'\t'}"
  echo '__TNA_NODE_IDENTITY_V1_BEGIN__'
  printf 'SERVER_ID=%s\n' "$(value SERVER_ID)"
  printf 'NODE_ID=%s\n' "$(value NODE_ID)"
  printf 'MACHINE_ID_SHA256=%s\n' "$(value MACHINE_ID_SHA256)"
  printf 'MACHINE_ID_MATCH=1\n'
  printf 'SSH_HOST_KEY_ALGORITHM=%s\n' "$(value SSH_HOST_KEY_ALGORITHM)"
  printf 'SSH_HOST_KEY_SHA256=%s\n' "$(value SSH_HOST_KEY_SHA256)"
  if [ "$(value SSH_HOST_KEY_ALGORITHM)" = "$current_algorithm" ] && [ "$(value SSH_HOST_KEY_SHA256)" = "$current_fingerprint" ]; then
    echo 'SSH_HOST_KEY_MATCH=1'
  else
    echo 'SSH_HOST_KEY_MATCH=0'
  fi
  printf 'FIRST_KNOWN_PUBLIC_IP=%s\n' "$(value FIRST_KNOWN_PUBLIC_IP)"
  printf 'CURRENT_PUBLIC_IP=%s\n' "$(value CURRENT_PUBLIC_IP)"
  echo '__TNA_NODE_IDENTITY_V1_END__'
}

case "$MODE" in
  --init|init) init_state ;;
  --show|show) show_state ;;
  *) die USAGE 2 ;;
esac
