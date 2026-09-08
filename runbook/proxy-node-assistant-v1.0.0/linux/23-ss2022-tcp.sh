#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

MODE="${1:-status}"
shift || true

STATE_DIR="/etc/proxy-runbook/ss2022"
CONFIG_FILE="$STATE_DIR/server.json"
ALLOWLIST_FILE="$STATE_DIR/allowlist.txt"
META_FILE="$STATE_DIR/service.env"
UNIT_NAME="proxy-node-assistant-ss2022.service"
UNIT_FILE="/etc/systemd/system/$UNIT_NAME"
HELPER_DIR="/usr/local/libexec/proxy-node-assistant"
FIREWALL_HELPER="$HELPER_DIR/ss2022-firewall"
HANDOFF_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib-handoff.sh"
PUBLIC_ENV="/etc/proxy-runbook/public.env"
# Formal v1 listener.  Existing 30443 trial state is still migratable when
# the caller passes it explicitly or when it is recovered from TRIAL_CONFIG.
DEFAULT_PORT=32443
METHOD="2022-blake3-aes-256-gcm"
OWNER="ProxyNodeAssistant-v1.0.0"
TRIAL_UNIT="tna-ss2022-112-trial.service"
TRIAL_CONFIG="/run/tna-ss2022-112-trial.json"
TRIAL_MIGRATION=0
TRIAL_STOPPED=0
TRIAL_ORIGINAL_PORT=""
TRIAL_CUTOVER_PENDING=0
FORMAL_COMMITTED=0
MIGRATION_ROOT=""
ROLLBACK_XRAY=""

die() {
  printf 'PNA_SS2022_ERROR=%s\n' "$*" >&2
  exit 1
}

require_root() {
  [ "$(id -u)" -eq 0 ] || die "run_as_root"
}

valid_port() {
  [[ "$1" =~ ^[0-9]+$ ]] && [ "$1" -ge 1024 ] && [ "$1" -le 65535 ]
}

normalize_source() {
  python3 - "$1" <<'PY'
import ipaddress, sys
try:
    value = sys.argv[1].strip()
    if "/" in value:
        raise ValueError("CIDR ranges are not accepted; add the exact current IPv4 address")
    obj = ipaddress.ip_address(value)
    if obj.version != 4 or not obj.is_global:
        raise ValueError("only exact global IPv4 addresses are accepted")
    print(obj.compressed)
except Exception:
    raise SystemExit(1)
PY
}

rollback_migration() {
  local rc=$? restore_config=""
  trap - EXIT
  if [ "$rc" -ne 0 ] && [ "$TRIAL_MIGRATION" -eq 1 ] && [ "$TRIAL_STOPPED" -eq 1 ] && [ "$FORMAL_COMMITTED" -ne 1 ]; then
    printf 'PNA_SS2022_ROLLBACK=STARTED\n' >&2
    systemctl disable --now "$UNIT_NAME" >/dev/null 2>&1 || true
    [ ! -x "$FIREWALL_HELPER" ] || "$FIREWALL_HELPER" remove >/dev/null 2>&1 || true
    systemctl reset-failed "$TRIAL_UNIT" >/dev/null 2>&1 || true
    if command -v ufw >/dev/null 2>&1 && [ -s "$ALLOWLIST_FILE" ]; then
      local rollback_port rollback_source
      rollback_port="$(meta_value PORT)"
      if valid_port "${rollback_port:-0}"; then
        while IFS= read -r rollback_source; do
          [ -n "$rollback_source" ] || continue
          ufw allow proto tcp from "$rollback_source" to any port "$rollback_port" \
            comment 'tna-ss2022-112-trial' >/dev/null 2>&1 || true
        done < "$ALLOWLIST_FILE"
      fi
    fi
    if [ -r "$TRIAL_CONFIG" ]; then
      restore_config="$TRIAL_CONFIG"
    elif [ -n "$MIGRATION_ROOT" ] && [ -r "$MIGRATION_ROOT/trial-server.json" ]; then
      install -m 600 "$MIGRATION_ROOT/trial-server.json" "$TRIAL_CONFIG" || true
      restore_config="$TRIAL_CONFIG"
    fi
    if [ -n "$restore_config" ] && [ -x "$ROLLBACK_XRAY" ]; then
      systemd-run --quiet --unit="${TRIAL_UNIT%.service}" \
        --property=Type=simple --property=Restart=no \
        --property=RuntimeMaxSec=12h --collect \
        "$ROLLBACK_XRAY" run -c "$restore_config" >/dev/null 2>&1 || true
      sleep 1
    fi
    if systemctl is-active --quiet "$TRIAL_UNIT" 2>/dev/null; then
      printf 'PNA_SS2022_ROLLBACK=RESTORED_TRIAL\n' >&2
    else
      printf 'PNA_SS2022_ROLLBACK=FAILED_MANUAL_CONSOLE_REQUIRED\n' >&2
    fi
  fi
  exit "$rc"
}

trap rollback_migration EXIT

meta_value() {
  local key="$1"
  sed -n "s/^${key}=//p" "$META_FILE" 2>/dev/null | sed -n '1p'
}

detect_xray() {
  local candidate
  for candidate in \
    /usr/local/x-ui/bin/xray-linux-amd64 \
    /usr/local/x-ui/bin/xray-linux-arm64 \
    /usr/local/x-ui/bin/xray \
    /usr/local/bin/xray \
    /usr/bin/xray; do
    if [ -x "$candidate" ]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  candidate="$(find /usr/local/x-ui/bin -maxdepth 1 -type f -name 'xray*' -perm -111 2>/dev/null | sort | sed -n '1p')"
  [ -n "$candidate" ] || return 1
  printf '%s\n' "$candidate"
}

extract_trial_sources() {
  command -v ufw >/dev/null 2>&1 || return 0
  {
    ufw show added 2>/dev/null \
    | awk -v port="$1" '
        index($0, "tna-ss2022-112-trial") && $0 ~ ("port " port " ") {
          for (i=1; i<=NF; i++) if ($i=="from" && (i+1)<=NF) print $(i+1)
        }
      '
    ufw status numbered 2>/dev/null \
      | awk -v port="$1" '
          index($0, "tna-ss2022-112-trial") && index($0, port "/tcp") {
            for (i=1; i<=NF; i++) if ($i=="IN" && (i+1)<=NF) print $(i+1)
          }
        '
  } | sort -u || true
}

remove_trial_ufw_rules() {
  command -v ufw >/dev/null 2>&1 || {
    printf 'PNA_SS2022_TRIAL_CLEANUP_OK=ufw_unavailable\n' >&2
    return 0
  }
  local number status_output
  while :; do
    # With `set -o pipefail`, a deliberately empty grep result has status 1.
    # The old command substitution therefore aborted the whole SS2022 stage
    # immediately after deleting the last trial rule, before FORMAL_COMMITTED
    # was set.  Keep the UFW command separate from the expected no-match
    # filter so trial-rule cleanup cannot roll back an already verified formal
    # listener.
    # Read UFW output first so a real UFW failure is distinguishable from an
    # ordinary no-match.  The second pipeline contains no grep and therefore
    # remains successful when there are no tagged trial rules.
    if ! status_output="$(ufw status numbered 2>/dev/null)"; then
      printf 'PNA_SS2022_TRIAL_CLEANUP_WARN=ufw_status_failed\n' >&2
      return 0
    fi
    number="$(printf '%s\n' "$status_output" \
      | sed -n '/tna-ss2022-112-trial/s/^\[[[:space:]]*\([0-9]\+\)\].*/\1/p' \
      | sort -rn | sed -n '1p')"
    [ -n "$number" ] || break
    # Feed exactly one confirmation.  An unbounded `yes` can receive SIGPIPE
    # when UFW exits after the first answer; with `pipefail` that looks like a
    # failed cleanup even though UFW succeeded and can leave the trial rule.
    if ! printf 'y\n' | ufw delete "$number" >/dev/null 2>&1; then
      printf 'PNA_SS2022_TRIAL_CLEANUP_WARN=ufw_delete_%s\n' "$number" >&2
      return 0
    fi
  done
  printf 'PNA_SS2022_TRIAL_CLEANUP_OK=1\n'
}

install_firewall_helper() {
  local tmp
  install -d -m 755 "$HELPER_DIR"
  # systemd may invoke ExecStartPre/ExecReload while an installer is replacing
  # this helper.  Write in the same directory and rename atomically so a
  # callback can only observe the old complete file or the new complete file,
  # never a truncated heredoc.
  tmp="$(mktemp "$HELPER_DIR/.ss2022-firewall.XXXXXX")"
  if ! cat > "$tmp" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
STATE_DIR="/etc/proxy-runbook/ss2022"
META_FILE="$STATE_DIR/service.env"
ALLOWLIST_FILE="$STATE_DIR/allowlist.txt"
CHAIN="PNA_SS2022"
NEXT="PNA_SS2022_NEXT"
LOCK_FILE="/run/lock/proxy-node-assistant-ss2022-firewall.lock"

[ "$(id -u)" -eq 0 ] || exit 1
command -v flock >/dev/null 2>&1 || { printf 'PNA_SS2022_FIREWALL_ERROR=flock_missing\n' >&2; exit 1; }
install -d -m 755 "$(dirname "$LOCK_FILE")"
exec 9>"$LOCK_FILE"
chmod 600 "$LOCK_FILE" 2>/dev/null || true
# ExecStartPre, ExecReload, and ExecStopPost can overlap when systemd is
# restarting a service while the installer performs its explicit final apply.
# Serialize the helper so one invocation cannot delete the chain while another
# is validating it.  A bounded wait avoids hanging the service forever.
flock -w 30 9 || { printf 'PNA_SS2022_FIREWALL_ERROR=concurrent_operation_timeout\n' >&2; exit 75; }
PORT="$(sed -n 's/^PORT=//p' "$META_FILE" 2>/dev/null | sed -n '1p')"
[[ "$PORT" =~ ^[0-9]+$ ]] || exit 1

chain_exists() {
  iptables -w 5 -n -L "$1" >/dev/null 2>&1
}

# A previous run may have inserted the managed jump with a different port
# (for example, while moving the 30443 trial to the formal 32443 listener),
# or a UFW/fail2ban reload may have copied the jump into another user chain.
# Matching only INPUT + the current --dport leaves those stale references in
# place; iptables then refuses to delete/rename PNA_SS2022 and the service
# fails with an unhelpful rc=1. Enumerate every chain and remove references by
# line number instead. The target names are private to this helper, so this
# cannot remove an unrelated rule.
list_chains() {
  {
    printf '%s\n' INPUT FORWARD OUTPUT
    iptables -w 5 -S 2>/dev/null \
      | awk '$1 == "-P" || $1 == "-N" { print $2 }'
  } | awk 'NF && !seen[$0]++'
}

remove_target_jumps() {
  local target="$1" chain line
  while IFS= read -r chain; do
    [ -n "$chain" ] || continue
    while :; do
      line="$(iptables -w 5 -L "$chain" -n --line-numbers 2>/dev/null \
        | awk -v target="$target" '$1 ~ /^[0-9]+$/ && $2 == target { print $1; exit }')"
      [ -n "$line" ] || break
      # Deleting by line number also handles jumps whose original rule had a
      # different port, protocol-module ordering, source, or comment.
      iptables -w 5 -D "$chain" "$line"
    done
  done < <(list_chains)
}

delete_chain() {
  local chain="$1"
  if chain_exists "$chain"; then
    iptables -w 5 -F "$chain"
    iptables -w 5 -X "$chain"
  fi
}

count_target_jumps() {
  local target="$1" chain count=0
  while IFS= read -r chain; do
    [ -n "$chain" ] || continue
    while IFS= read -r _; do
      count=$((count + 1))
    done < <(iptables -w 5 -L "$chain" -n --line-numbers 2>/dev/null \
      | awk -v target="$target" '$1 ~ /^[0-9]+$/ && $2 == target { print $1 }')
  done < <(list_chains)
  printf '%s\n' "$count"
}

case "${1:-apply}" in
  apply)
    command -v iptables >/dev/null 2>&1 || exit 1
    # Remove stale generations first. This is deliberately all-chain and
    # all-port so an interrupted port migration cannot strand a reference.
    remove_target_jumps "$NEXT"
    delete_chain "$NEXT"
    iptables -w 5 -N "$NEXT"
    if [ -s "$ALLOWLIST_FILE" ]; then
      while IFS= read -r source; do
        [ -n "$source" ] || continue
        iptables -w 5 -A "$NEXT" -s "$source" -j ACCEPT
      done < "$ALLOWLIST_FILE"
    fi
    iptables -w 5 -A "$NEXT" -j DROP
    # PNA_SS2022 may still be referenced by an older port rule or a UFW
    # helper chain. Remove every such reference before deleting the old chain;
    # otherwise `iptables -E` returns rc=1 and systemd hides the cause.
    remove_target_jumps "$CHAIN"
    delete_chain "$CHAIN"
    iptables -w 5 -E "$NEXT" "$CHAIN"
    # Exactly one jump is installed at the top of INPUT. Rebuilding it from
    # line numbers above makes repeated ExecStartPre/ExecReload calls
    # idempotent and prevents duplicate PNA_SS2022 rules.
    iptables -w 5 -I INPUT 1 -p tcp --dport "$PORT" -j "$CHAIN"
    ;;
  remove)
    remove_target_jumps "$NEXT"
    remove_target_jumps "$CHAIN"
    delete_chain "$NEXT"
    delete_chain "$CHAIN"
    ;;
  verify)
    [ "$(count_target_jumps "$CHAIN")" -eq 1 ]
    iptables -w 5 -C INPUT -p tcp --dport "$PORT" -j "$CHAIN" >/dev/null 2>&1
    iptables -w 5 -C "$CHAIN" -j DROP >/dev/null 2>&1
    first_target="$(iptables -w 5 -L INPUT -n --line-numbers 2>/dev/null | awk '$1 == 1 {print $2; exit}')"
    [ "$first_target" = "$CHAIN" ]
    last_rule="$(iptables -w 5 -S "$CHAIN" 2>/dev/null | awk '/^-A / { last=$0 } END { print last }')"
    [ "$last_rule" = "-A $CHAIN -j DROP" ]
    expected=0
    if [ -s "$ALLOWLIST_FILE" ]; then
      while IFS= read -r source; do
        [ -n "$source" ] || continue
        iptables -w 5 -C "$CHAIN" -s "$source" -j ACCEPT >/dev/null 2>&1
        expected=$((expected+1))
      done < "$ALLOWLIST_FILE"
    fi
    actual="$(iptables -w 5 -S "$CHAIN" 2>/dev/null | awk '$1 == "-A" && $(NF-1) == "-j" && $NF == "ACCEPT" { count++ } END { print count + 0 }')"
    [ "$actual" -eq "$expected" ]
    ;;
  *) exit 2 ;;
esac
EOF
  then
    rm -f -- "$tmp"
    die "firewall_helper_write_failed"
  fi
  chmod 755 "$tmp"
  mv -f -- "$tmp" "$FIREWALL_HELPER"
}

write_metadata() {
  local port="$1" xray="$2" migrated="$3" trial_source_port="${4:-}" cutover_pending="${5:-0}" tmp
  tmp="$(mktemp)"
  {
    echo 'FORMAT_VERSION=1'
    printf 'OWNER=%s\n' "$OWNER"
    printf 'PORT=%s\n' "$port"
    printf 'METHOD=%s\n' "$METHOD"
    echo 'NETWORK=tcp'
    printf 'XRAY_PATH=%s\n' "$xray"
    printf 'MIGRATED_TRIAL=%s\n' "$migrated"
    printf 'TRIAL_SOURCE_PORT=%s\n' "$trial_source_port"
    printf 'TRIAL_CUTOVER_PENDING=%s\n' "$cutover_pending"
    printf 'UPDATED_AT=%s\n' "$(date -Is)"
  } > "$tmp"
  install -m 600 "$tmp" "$META_FILE"
  rm -f "$tmp"
}

write_unit() {
  local xray="$1" tmp
  if [ -e "$UNIT_FILE" ] && ! grep -Fqx '# Managed by ProxyNodeAssistant v1.0.0' "$UNIT_FILE" 2>/dev/null; then
    die "refused_unmanaged_unit"
  fi
  tmp="$(mktemp "$(dirname "$UNIT_FILE")/.proxy-node-assistant-ss2022.service.XXXXXX")"
  if ! cat > "$tmp" <<EOF
# Managed by ProxyNodeAssistant v1.0.0
[Unit]
Description=ProxyNodeAssistant Shadowsocks 2022 TCP-only service
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStartPre=$FIREWALL_HELPER apply
ExecStart=$xray run -c $CONFIG_FILE
ExecReload=$FIREWALL_HELPER apply
ExecStopPost=$FIREWALL_HELPER remove
Restart=on-failure
RestartSec=2s
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ProtectSystem=full
ReadOnlyPaths=$STATE_DIR

[Install]
WantedBy=multi-user.target
EOF
  then
    rm -f -- "$tmp"
    die "unit_write_failed"
  fi
  chmod 644 "$tmp"
  mv -f -- "$tmp" "$UNIT_FILE"
}

generate_config() {
  local port="$1" secret tmp
  secret="$(openssl rand -base64 32 | tr -d '\r\n')"
  [ -n "$secret" ] || die "secret_generation_failed"
  tmp="$(mktemp)"
  jq -n \
    --argjson port "$port" \
    --arg method "$METHOD" \
    --arg password "$secret" \
    '{
      log:{loglevel:"warning"},
      inbounds:[{
        listen:"0.0.0.0", port:$port, protocol:"shadowsocks",
        settings:{method:$method,password:$password,network:"tcp"}
      }],
      outbounds:[{protocol:"freedom",tag:"direct"}]
    }' > "$tmp"
  install -m 600 "$tmp" "$CONFIG_FILE"
  rm -f "$tmp"
}

validate_config() {
  local xray="$1" port="$2"
  jq -e \
    --arg method "$METHOD" --argjson port "$port" '
      (.inbounds|length)==1 and
      .inbounds[0].protocol=="shadowsocks" and
      .inbounds[0].port==$port and
      .inbounds[0].settings.method==$method and
      .inbounds[0].settings.network=="tcp" and
      (.inbounds[0].settings.password|type=="string" and length>=32)
    ' "$CONFIG_FILE" >/dev/null || die "invalid_server_config"
  "$xray" run -test -c "$CONFIG_FILE" >/dev/null 2>&1 || die "xray_rejected_server_config"
}

sync_public_metadata() {
  local port="$1" tmp
  install -d -m 755 "$(dirname "$PUBLIC_ENV")"
  tmp="$(mktemp)"
  if [ -f "$PUBLIC_ENV" ]; then
    grep -Ev '^(SS2022_PORT|SS2022_METHOD|SS2022_NETWORK|SS2022_UNIT)=' "$PUBLIC_ENV" > "$tmp" || true
  fi
  {
    printf 'SS2022_PORT=%s\n' "$port"
    printf 'SS2022_METHOD=%s\n' "$METHOD"
    echo 'SS2022_NETWORK=tcp'
    printf 'SS2022_UNIT=%s\n' "$UNIT_NAME"
  } >> "$tmp"
  install -m 644 "$tmp" "$PUBLIC_ENV"
  rm -f "$tmp"
}

write_handoff() {
  [ -r "$HANDOFF_LIB" ] || die "handoff_library_missing"
  # shellcheck source=/dev/null
  . "$HANDOFF_LIB"
  local port password public_ip userinfo uri
  port="$(meta_value PORT)"
  password="$(jq -r '.inbounds[0].settings.password // empty' "$CONFIG_FILE")"
  public_ip="$(sed -n 's/^PUBLIC_IP=//p' "$PUBLIC_ENV" 2>/dev/null | sed -n '1p')"
  [ -n "$public_ip" ] || public_ip="$(curl -4fsS --max-time 8 https://api.ipify.org 2>/dev/null || true)"
  [ -n "$public_ip" ] || die "public_ip_unavailable"
  [ -n "$password" ] || die "password_unavailable"
  userinfo="$(printf '%s:%s' "$METHOD" "$password" | base64 -w0 | tr '+/' '-_' | tr -d '=')"
  uri="ss://${userinfo}@${public_ip}:${port}#ProxyNodeAssistant-SS2022-TCP"
  handoff_set "SS2022_ENABLED" "1"
  handoff_set "SS2022_SERVER_ADDRESS" "$public_ip"
  handoff_set "SS2022_PORT" "$port"
  handoff_set "SS2022_METHOD" "$METHOD"
  handoff_set "SS2022_PASSWORD" "$password"
  handoff_set "SS2022_TRANSPORT" "TCP_ONLY"
  handoff_set "SS2022_ALLOWLIST_MODE" "EXACT_IPV4_SOURCE_ONLY"
  handoff_set "SS2022_ALLOWLIST_UPDATED_AT" "$(date -Is)"
  handoff_set "SS2022_LINK" "$uri"
  if [ "$(meta_value MIGRATED_TRIAL)" = "1" ]; then
    handoff_set "SS2022_MIGRATED_FROM" "$TRIAL_UNIT"
  fi
}

ensure_service() {
  local requested_port="${1:-$DEFAULT_PORT}" initial_source="${2:-}" xray migrated=0 trial_port="" tmp source
  valid_port "$requested_port" || die "invalid_port"
  command -v jq >/dev/null 2>&1 || die "jq_missing"
  command -v openssl >/dev/null 2>&1 || die "openssl_missing"
  command -v python3 >/dev/null 2>&1 || die "python3_missing"
  xray="$(detect_xray)" || die "xray_missing"
  ROLLBACK_XRAY="$xray"
  install -d -m 700 "$STATE_DIR"
  touch "$ALLOWLIST_FILE"
  chmod 600 "$ALLOWLIST_FILE"

  if { [ -s "$META_FILE" ] && [ ! -s "$CONFIG_FILE" ]; } || { [ -s "$CONFIG_FILE" ] && [ ! -s "$META_FILE" ]; }; then
    die "partial_managed_state_refused"
  fi
  if [ -s "$META_FILE" ] && [ "$(meta_value OWNER)" != "$OWNER" ]; then
    die "refused_unmanaged_state"
  fi

  if systemctl is-active --quiet "$TRIAL_UNIT" 2>/dev/null; then
    [ -r "$TRIAL_CONFIG" ] || die "active_trial_config_missing_refused"
    trial_port="$(jq -r '.inbounds[0].port // empty' "$TRIAL_CONFIG" 2>/dev/null || true)"
    valid_port "${trial_port:-0}" || die "active_trial_port_invalid_refused"
  fi

  if [ ! -s "$CONFIG_FILE" ] && [ -r "$TRIAL_CONFIG" ]; then
    trial_port="$(jq -r '.inbounds[0].port // empty' "$TRIAL_CONFIG" 2>/dev/null || true)"
    if valid_port "${trial_port:-0}" && jq -e \
      --arg method "$METHOD" '
        .inbounds[0].protocol=="shadowsocks" and
        .inbounds[0].settings.method==$method and
        .inbounds[0].settings.network=="tcp" and
        (.inbounds[0].settings.password|type=="string" and length>=32)
      ' "$TRIAL_CONFIG" >/dev/null 2>&1; then
      tmp="$(mktemp)"
      jq --argjson port "$requested_port" '.inbounds[0].port=$port' "$TRIAL_CONFIG" > "$tmp"
      install -m 600 "$tmp" "$CONFIG_FILE"
      rm -f -- "$tmp"
      migrated=1
      TRIAL_MIGRATION=1
      TRIAL_ORIGINAL_PORT="$trial_port"
      if [ "$trial_port" != "$requested_port" ]; then
        TRIAL_CUTOVER_PENDING=1
      fi
      while IFS= read -r source; do
        source="$(normalize_source "$source" 2>/dev/null || true)"
        [ -n "$source" ] && printf '%s\n' "$source" >> "$ALLOWLIST_FILE"
      done < <(extract_trial_sources "$trial_port")
    fi
  fi

  if [ -n "$initial_source" ]; then
    source="$(normalize_source "$initial_source")" || die "invalid_initial_source"
    printf '%s\n' "$source" >> "$ALLOWLIST_FILE"
  fi
  sort -u -o "$ALLOWLIST_FILE" "$ALLOWLIST_FILE"

  if [ "$migrated" -eq 1 ] && [ ! -s "$ALLOWLIST_FILE" ]; then
    die "trial_allowlist_source_not_recovered"
  fi

  if [ ! -s "$CONFIG_FILE" ]; then
    if ss -ltn "( sport = :$requested_port )" 2>/dev/null | grep -q LISTEN; then
      die "port_in_use_by_unknown_service"
    fi
    generate_config "$requested_port"
  fi

  validate_config "$xray" "$requested_port"
  if [ "$(jq -r '.inbounds[0].port // empty' "$CONFIG_FILE")" != "$requested_port" ]; then
    die "existing_config_port_mismatch"
  fi
  write_metadata "$requested_port" "$xray" "$migrated" "$TRIAL_ORIGINAL_PORT" "$TRIAL_CUTOVER_PENDING"
  install_firewall_helper
  write_unit "$xray"

  if [ "$migrated" -eq 1 ]; then
    MIGRATION_ROOT="/root/.config/proxy-runbook/ss2022-migration/$(date -u +%Y%m%d-%H%M%S)"
    install -d -m 700 "$MIGRATION_ROOT"
    install -m 600 "$TRIAL_CONFIG" "$MIGRATION_ROOT/trial-server.json"
    systemctl cat "$TRIAL_UNIT" > "$MIGRATION_ROOT/trial-unit.txt" 2>&1 || true
    ufw status numbered > "$MIGRATION_ROOT/ufw-before.txt" 2>&1 || true
    ss -ltnp "( sport = :$requested_port )" > "$MIGRATION_ROOT/listener-before.txt" 2>&1 || true
    chmod 600 "$MIGRATION_ROOT"/* 2>/dev/null || true
  fi

  # Stop the transient experiment only after its credential and allowlist have
  # been adopted and the persistent unit has been fully staged.
  if [ "$migrated" -eq 1 ] && [ "$TRIAL_CUTOVER_PENDING" -eq 0 ] && systemctl is-active --quiet "$TRIAL_UNIT" 2>/dev/null; then
    systemctl stop "$TRIAL_UNIT" >/dev/null
    TRIAL_STOPPED=1
    systemctl reset-failed "$TRIAL_UNIT" >/dev/null 2>&1 || true
  fi
  systemctl daemon-reload
  systemctl enable --now "$UNIT_NAME" >/dev/null
  sleep 1
  "$FIREWALL_HELPER" apply
  systemctl is-active --quiet "$UNIT_NAME" || die "service_not_active"
  systemctl is-enabled --quiet "$UNIT_NAME" || die "service_not_enabled"
  ss -ltn "( sport = :$requested_port )" 2>/dev/null | grep -q LISTEN || die "listener_missing"
  "$FIREWALL_HELPER" verify || die "firewall_not_enforced"
  sync_public_metadata "$requested_port"
  write_handoff
  if [ "$TRIAL_CUTOVER_PENDING" -eq 0 ]; then
    remove_trial_ufw_rules
    rm -f -- "$TRIAL_CONFIG"
  fi
  FORMAL_COMMITTED=1
  printf 'PNA_SS2022_ENSURED=1\n'
  printf 'PNA_SS2022_PORT=%s\n' "$requested_port"
  printf 'PNA_SS2022_MIGRATED_TRIAL=%s\n' "$migrated"
  printf 'PNA_SS2022_TRIAL_SOURCE_PORT=%s\n' "${TRIAL_ORIGINAL_PORT:-}"
  printf 'PNA_SS2022_TRIAL_CUTOVER_PENDING=%s\n' "$TRIAL_CUTOVER_PENDING"
  printf 'PNA_SS2022_ALLOWLIST_COUNT=%s\n' "$(grep -c . "$ALLOWLIST_FILE" 2>/dev/null || true)"
  trap - EXIT
}

retire_trial_after_verify() {
  local expected_old_port="${1:-}" configured_old_port current_port tmp
  [ -s "$META_FILE" ] && [ -s "$CONFIG_FILE" ] || die "service_not_installed"
  [ "$(meta_value OWNER)" = "$OWNER" ] || die "refused_unmanaged_state"
  [ "$(meta_value TRIAL_CUTOVER_PENDING)" = "1" ] || die "no_trial_cutover_pending"
  configured_old_port="$(meta_value TRIAL_SOURCE_PORT)"
  valid_port "$configured_old_port" || die "trial_source_port_invalid"
  [ -z "$expected_old_port" ] || [ "$expected_old_port" = "$configured_old_port" ] || die "trial_source_port_confirmation_mismatch"
  current_port="$(meta_value PORT)"
  systemctl is-active --quiet "$UNIT_NAME" || die "formal_service_not_active"
  ss -ltn "( sport = :$current_port )" 2>/dev/null | grep -q LISTEN || die "formal_listener_missing"
  "$FIREWALL_HELPER" verify || die "formal_firewall_not_enforced"
  systemctl stop "$TRIAL_UNIT" >/dev/null 2>&1 || true
  systemctl reset-failed "$TRIAL_UNIT" >/dev/null 2>&1 || true
  remove_trial_ufw_rules
  rm -f -- "$TRIAL_CONFIG"
  tmp="$(mktemp)"
  sed 's/^TRIAL_CUTOVER_PENDING=.*/TRIAL_CUTOVER_PENDING=0/' "$META_FILE" > "$tmp"
  install -m 600 "$tmp" "$META_FILE"
  rm -f -- "$tmp"
  printf 'PNA_SS2022_TRIAL_RETIRED_PORT=%s\n' "$configured_old_port"
}

allow_source() {
  local source candidate previous
  [ -s "$META_FILE" ] || die "service_not_installed"
  [ "$(meta_value OWNER)" = "$OWNER" ] || die "refused_unmanaged_state"
  source="$(normalize_source "${1:-}")" || die "invalid_source"
  candidate="$(mktemp)"
  previous="$(mktemp)"
  cp -f -- "$ALLOWLIST_FILE" "$previous"
  { cat "$ALLOWLIST_FILE"; printf '%s\n' "$source"; } | sed '/^[[:space:]]*$/d' | sort -u > "$candidate"
  install -m 600 "$candidate" "$ALLOWLIST_FILE"
  if ! "$FIREWALL_HELPER" apply || ! "$FIREWALL_HELPER" verify; then
    install -m 600 "$previous" "$ALLOWLIST_FILE"
    "$FIREWALL_HELPER" apply >/dev/null 2>&1 || true
    rm -f -- "$candidate" "$previous"
    die "allowlist_apply_failed_rolled_back"
  fi
  rm -f -- "$candidate" "$previous"
  write_handoff
  printf 'PNA_SS2022_ALLOW_ADDED=%s\n' "$source"
}

remove_source() {
  local source candidate previous
  [ -s "$META_FILE" ] || die "service_not_installed"
  [ "$(meta_value OWNER)" = "$OWNER" ] || die "refused_unmanaged_state"
  source="$(normalize_source "${1:-}")" || die "invalid_source"
  candidate="$(mktemp)"
  previous="$(mktemp)"
  cp -f -- "$ALLOWLIST_FILE" "$previous"
  grep -Fxv "$source" "$ALLOWLIST_FILE" > "$candidate" || true
  install -m 600 "$candidate" "$ALLOWLIST_FILE"
  if ! "$FIREWALL_HELPER" apply || ! "$FIREWALL_HELPER" verify; then
    install -m 600 "$previous" "$ALLOWLIST_FILE"
    "$FIREWALL_HELPER" apply >/dev/null 2>&1 || true
    rm -f -- "$candidate" "$previous"
    die "allowlist_apply_failed_rolled_back"
  fi
  rm -f -- "$candidate" "$previous"
  write_handoff
  printf 'PNA_SS2022_ALLOW_REMOVED=%s\n' "$source"
}

status() {
  local port active=0 listener=0 firewall=0 present=0
  port="$(meta_value PORT)"
  [ -s "$META_FILE" ] && [ -s "$CONFIG_FILE" ] && present=1
  systemctl is-active --quiet "$UNIT_NAME" 2>/dev/null && active=1
  if valid_port "${port:-0}" && ss -ltn "( sport = :$port )" 2>/dev/null | grep -q LISTEN; then listener=1; fi
  if [ -x "$FIREWALL_HELPER" ] && "$FIREWALL_HELPER" verify >/dev/null 2>&1; then firewall=1; fi
  echo 'PNA_SS2022_STATUS_BEGIN'
  printf 'PRESENT=%s\n' "$present"
  printf 'ACTIVE=%s\n' "$active"
  printf 'LISTENER=%s\n' "$listener"
  printf 'FIREWALL=%s\n' "$firewall"
  printf 'PORT=%s\n' "${port:-$DEFAULT_PORT}"
  printf 'METHOD=%s\n' "$METHOD"
  echo 'NETWORK=tcp'
  printf 'ALLOWLIST_COUNT=%s\n' "$(grep -c . "$ALLOWLIST_FILE" 2>/dev/null || true)"
  echo 'PNA_SS2022_STATUS_END'
  [ "$present" -eq 1 ] && [ "$active" -eq 1 ] && [ "$listener" -eq 1 ] && [ "$firewall" -eq 1 ]
}

list_sources() {
  echo 'PNA_SS2022_ALLOWLIST_BEGIN'
  if [ -s "$ALLOWLIST_FILE" ]; then
    sed 's/^/SOURCE=/' "$ALLOWLIST_FILE"
  fi
  echo 'PNA_SS2022_ALLOWLIST_END'
}

# The ordinary `list` command is kept byte-for-byte compatible with the
# original maintenance flow.  `snapshot` uses this stricter emitter instead:
# it rejects a hand-edited state file containing a range, a private address,
# a malformed line, or duplicate entries before returning data to a client.
# This keeps the machine-readable management path fail-closed while retaining
# the small atomic `allow` / `remove` / `list` primitives for older clients.
list_sources_strict() {
  local source normalized
  declare -A seen=()
  [ -s "$META_FILE" ] || die "service_not_installed"
  [ "$(meta_value OWNER)" = "$OWNER" ] || die "refused_unmanaged_state"
  [ -f "$ALLOWLIST_FILE" ] || die "allowlist_missing"
  echo 'PNA_SS2022_ALLOWLIST_BEGIN'
  while IFS= read -r source || [ -n "$source" ]; do
    # Empty lines are not entries.  They are ignored here rather than emitted
    # as an ambiguous `SOURCE=` record.
    [ -n "$source" ] || continue
    normalized="$(normalize_source "$source" 2>/dev/null || true)"
    [ -n "$normalized" ] && [ "$normalized" = "$source" ] || die "invalid_allowlist_state"
    [[ -z "${seen[$source]+present}" ]] || die "duplicate_allowlist_state"
    seen["$source"]=1
    printf 'SOURCE=%s\n' "$source"
    previous="$source"
  done < "$ALLOWLIST_FILE"
  echo 'PNA_SS2022_ALLOWLIST_END'
}

# Read the status and allowlist as one fail-closed operation.  `status` is
# deliberately called first and its non-zero result is propagated, so an
# inactive service, missing listener, or unenforced firewall can never be
# mistaken for a healthy empty list.  On success the existing status/list
# markers are emitted unchanged for clients that already parse them.
snapshot() {
  status || return $?
  list_sources_strict
}

uninstall_service() {
  local purge_state="${1:-keep-state}"
  if [ -e "$UNIT_FILE" ] && ! grep -Fqx '# Managed by ProxyNodeAssistant v1.0.0' "$UNIT_FILE" 2>/dev/null; then
    die "refused_unmanaged_unit"
  fi
  if [ -s "$META_FILE" ] && [ "$(meta_value OWNER)" != "$OWNER" ]; then
    die "refused_unmanaged_state"
  fi
  systemctl disable --now "$UNIT_NAME" >/dev/null 2>&1 || true
  [ ! -x "$FIREWALL_HELPER" ] || "$FIREWALL_HELPER" remove >/dev/null 2>&1 || true
  rm -f -- "$UNIT_FILE" "$FIREWALL_HELPER"
  systemctl daemon-reload
  if [ "$purge_state" = "purge-state" ]; then
    rm -rf -- "$STATE_DIR"
    if [ -f "$PUBLIC_ENV" ]; then
      local tmp
      tmp="$(mktemp)"
      grep -Ev '^(SS2022_PORT|SS2022_METHOD|SS2022_NETWORK|SS2022_UNIT)=' "$PUBLIC_ENV" > "$tmp" || true
      install -m 644 "$tmp" "$PUBLIC_ENV"
      rm -f "$tmp"
    fi
    if [ -r "$HANDOFF_LIB" ]; then
      # shellcheck source=/dev/null
      . "$HANDOFF_LIB"
      local key
      for key in SS2022_ENABLED SS2022_SERVER_ADDRESS SS2022_PORT SS2022_METHOD \
        SS2022_PASSWORD SS2022_TRANSPORT SS2022_ALLOWLIST_MODE \
        SS2022_ALLOWLIST_UPDATED_AT SS2022_LINK SS2022_MIGRATED_FROM; do
        handoff_delete "$key"
      done
    fi
  elif [ -r "$HANDOFF_LIB" ]; then
    # shellcheck source=/dev/null
    . "$HANDOFF_LIB"
    handoff_set "SS2022_ENABLED" "0"
  fi
  echo 'PNA_SS2022_UNINSTALLED=1'
}

require_root
install -d -m 755 /run/lock
exec 9>/run/lock/proxy-node-assistant-ss2022.lock
flock -n 9 || die "another_ss2022_operation_is_running"
case "$MODE" in
  ensure) ensure_service "${1:-$DEFAULT_PORT}" "${2:-}" ;;
  allow) allow_source "${1:-}" ;;
  remove) remove_source "${1:-}" ;;
  list) list_sources ;;
  snapshot) snapshot ;;
  status) status ;;
  handoff) write_handoff; echo 'PNA_SS2022_HANDOFF_UPDATED=1' ;;
  retire-trial-after-verify) retire_trial_after_verify "${1:-}" ;;
  firewall-apply) "$FIREWALL_HELPER" apply ;;
  uninstall) uninstall_service "${1:-keep-state}" ;;
  *) die "usage: $0 {ensure [port] [initial-ip]|allow ip|remove ip|list|snapshot|status|handoff|retire-trial-after-verify [old-port]|uninstall [keep-state|purge-state]}" ;;
esac
trap - EXIT
