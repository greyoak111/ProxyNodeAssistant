#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

MODE="${1:---status}"
RETENTION_DAYS="${2:-7}"
STATE_DIR="/etc/text-node-assistant"
STATE_FILE="$STATE_DIR/security-baseline.env"
JAIL_FILE="/etc/fail2ban/jail.d/text-node-assistant-sshd.local"
HELPER_DIR="/usr/local/lib/text-node-assistant"
FIREWALL_HELPER="$HELPER_DIR/security-firewall.sh"
FIREWALL_UNIT="/etc/systemd/system/text-node-assistant-security-firewall.service"
LOGROTATE_FILE="/etc/logrotate.d/text-node-assistant-security"
JAIL_MARKER="# TNA_MANAGED_FAIL2BAN_SSHD_V095"
HELPER_MARKER="# TNA_MANAGED_SECURITY_FIREWALL_V095"
UNIT_MARKER="# TNA_MANAGED_SECURITY_FIREWALL_UNIT_V095"
LOGROTATE_MARKER="# TNA_MANAGED_SECURITY_LOGROTATE_V095"

die() {
  printf 'TNA_SECURITY_BASELINE_ERROR=%s\n' "$1" >&2
  exit "${2:-1}"
}

require_root() {
  [ "$(id -u)" -eq 0 ] || die ROOT_REQUIRED 2
}

valid_retention() {
  [[ "$1" =~ ^[0-9]+$ ]] && [ "$1" -ge 1 ] && [ "$1" -le 30 ]
}

owned_or_absent() {
  local path="$1" marker="$2"
  [ ! -e "$path" ] || grep -Fqx "$marker" "$path" 2>/dev/null
}

ssh_port() {
  local port
  port="$(sshd -T 2>/dev/null | awk '$1=="port" && !seen {print $2; seen=1}')"
  [[ "${port:-}" =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ] || port=22
  printf '%s' "$port"
}

fail2ban_backend() {
  if [ -d /run/systemd/system ] && command -v journalctl >/dev/null 2>&1; then
    printf 'systemd'
  else
    printf 'auto'
  fi
}

write_firewall_helper() {
  install -d -m 755 "$HELPER_DIR"
  local tmp
  tmp="$(mktemp)"
  cat > "$tmp" <<'EOF'
#!/usr/bin/env bash
# TNA_MANAGED_SECURITY_FIREWALL_V095
set -Eeuo pipefail

COMMENT="TNA_REALITY_CONN_V095"
PREFIX="TNA-REALITY "

is_direct_reality() {
  grep -q '^PORT_443_OWNER=xray-reality$' /etc/text-node-assistant/deployment-mode.env 2>/dev/null ||
    ss -H -lntp 2>/dev/null | awk '$4 ~ /:443$/ && $0 ~ /xray/ {found=1} END{exit !found}'
}

has_rule() {
  iptables -C INPUT -p tcp --syn --dport 443 -m limit --limit 12/min --limit-burst 24 \
    -m comment --comment "$COMMENT" -j LOG --log-prefix "$PREFIX" --log-level 6 >/dev/null 2>&1
}

start_rule() {
  command -v iptables >/dev/null 2>&1 || exit 0
  is_direct_reality || exit 0
  has_rule || iptables -I INPUT 1 -p tcp --syn --dport 443 -m limit --limit 12/min --limit-burst 24 \
    -m comment --comment "$COMMENT" -j LOG --log-prefix "$PREFIX" --log-level 6
}

stop_rule() {
  command -v iptables >/dev/null 2>&1 || exit 0
  while has_rule; do
    iptables -D INPUT -p tcp --syn --dport 443 -m limit --limit 12/min --limit-burst 24 \
      -m comment --comment "$COMMENT" -j LOG --log-prefix "$PREFIX" --log-level 6
  done
}

case "${1:-status}" in
  start) start_rule ;;
  stop) stop_rule ;;
  restart) stop_rule; start_rule ;;
  status) if has_rule; then echo REALITY_METADATA_RULE=ACTIVE; else echo REALITY_METADATA_RULE=INACTIVE; fi ;;
  *) echo 'usage: security-firewall.sh {start|stop|restart|status}' >&2; exit 2 ;;
esac
EOF
  install -m 755 "$tmp" "$FIREWALL_HELPER"
  rm -f "$tmp"
}

write_firewall_unit() {
  local tmp
  tmp="$(mktemp)"
  cat > "$tmp" <<'EOF'
# TNA_MANAGED_SECURITY_FIREWALL_UNIT_V095
[Unit]
Description=TextNodeAssistant privacy-preserving connection metadata rule
After=network-online.target ufw.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/lib/text-node-assistant/security-firewall.sh start
ExecStop=/usr/local/lib/text-node-assistant/security-firewall.sh stop
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
  install -m 644 "$tmp" "$FIREWALL_UNIT"
  rm -f "$tmp"
}

write_logrotate() {
  local tmp
  tmp="$(mktemp)"
  cat > "$tmp" <<EOF
$LOGROTATE_MARKER
/var/log/nginx/text-node-assistant-security.log {
    daily
    rotate $RETENTION_DAYS
    missingok
    notifempty
    compress
    delaycompress
    create 0640 www-data adm
    sharedscripts
    postrotate
        systemctl reload nginx >/dev/null 2>&1 || true
    endscript
}
EOF
  install -m 644 "$tmp" "$LOGROTATE_FILE"
  rm -f "$tmp"
}

write_jail() {
  local port="$1" backend="$2" tmp old
  tmp="$(mktemp)"
  old="$(mktemp)"
  if [ -e "$JAIL_FILE" ]; then cp -a "$JAIL_FILE" "$old"; else : > "$old"; fi
  cat > "$tmp" <<EOF
$JAIL_MARKER
[sshd]
enabled = true
port = $port
backend = $backend
maxretry = 5
findtime = 10m
bantime = 1h
EOF
  install -d -m 755 /etc/fail2ban/jail.d
  install -m 644 "$tmp" "$JAIL_FILE"
  rm -f "$tmp"
  if ! fail2ban-client -t >/dev/null 2>&1; then
    if [ -s "$old" ]; then install -m 644 "$old" "$JAIL_FILE"; else rm -f "$JAIL_FILE"; fi
    rm -f "$old"
    die FAIL2BAN_CONFIG_TEST_FAILED 41
  fi
  rm -f "$old"
}

apply_baseline() {
  require_root
  valid_retention "$RETENTION_DAYS" || die INVALID_RETENTION_DAYS 3
  owned_or_absent "$JAIL_FILE" "$JAIL_MARKER" || die UNMANAGED_JAIL_CONFLICT 42
  owned_or_absent "$FIREWALL_HELPER" "$HELPER_MARKER" || die UNMANAGED_FIREWALL_HELPER_CONFLICT 43
  owned_or_absent "$FIREWALL_UNIT" "$UNIT_MARKER" || die UNMANAGED_FIREWALL_UNIT_CONFLICT 44
  owned_or_absent "$LOGROTATE_FILE" "$LOGROTATE_MARKER" || die UNMANAGED_LOGROTATE_CONFLICT 45

  if ! command -v fail2ban-client >/dev/null 2>&1; then
    DEBIAN_FRONTEND=noninteractive apt-get update -y >/dev/null
    DEBIAN_FRONTEND=noninteractive apt-get install -y fail2ban >/dev/null
  fi
  local port backend tmp
  port="$(ssh_port)"
  backend="$(fail2ban_backend)"
  write_jail "$port" "$backend"
  write_firewall_helper
  write_firewall_unit
  write_logrotate

  install -d -m 700 "$STATE_DIR"
  tmp="$(mktemp)"
  {
    echo 'SECURITY_BASELINE_VERSION=1'
    printf 'SSH_PORT=%s\n' "$port"
    printf 'FAIL2BAN_BACKEND=%s\n' "$backend"
    echo 'MAXRETRY=5'
    echo 'FINDTIME=10m'
    echo 'BANTIME=1h'
    printf 'RETENTION_DAYS=%s\n' "$RETENTION_DAYS"
    printf 'UPDATED_AT=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  } > "$tmp"
  install -m 600 "$tmp" "$STATE_FILE"
  rm -f "$tmp"

  systemctl daemon-reload
  systemctl enable --now fail2ban >/dev/null || die FAIL2BAN_DAEMON_START_FAILED 46
  fail2ban-client reload >/dev/null || die FAIL2BAN_RELOAD_FAILED 46
  fail2ban-client status sshd >/dev/null || die FAIL2BAN_SSHD_JAIL_NOT_ACTIVE 46
  systemctl enable --now text-node-assistant-security-firewall.service >/dev/null || die FIREWALL_METADATA_UNIT_START_FAILED 47
  "$FIREWALL_HELPER" restart
  echo 'TNA_SECURITY_BASELINE_APPLIED'
  status_baseline
}

status_baseline() {
  local port backend jail=0 daemon=0 rule=0 retention=""
  port="$(ssh_port)"
  backend="$(fail2ban_backend)"
  grep -Fqx "$JAIL_MARKER" "$JAIL_FILE" 2>/dev/null && jail=1
  systemctl is-active --quiet fail2ban 2>/dev/null && daemon=1
  if [ -x "$FIREWALL_HELPER" ] && "$FIREWALL_HELPER" status 2>/dev/null | grep -q '=ACTIVE$'; then rule=1; fi
  retention="$(sed -n 's/^RETENTION_DAYS=//p' "$STATE_FILE" 2>/dev/null | sed -n '1p' || true)"
  echo 'TNA_SECURITY_BASELINE_STATUS_BEGIN'
  printf 'FAIL2BAN_INSTALLED=%s\n' "$(command -v fail2ban-client >/dev/null 2>&1 && echo 1 || echo 0)"
  printf 'FAIL2BAN_DAEMON_ACTIVE=%s\n' "$daemon"
  printf 'FAIL2BAN_SSHD_MANAGED=%s\n' "$jail"
  printf 'FAIL2BAN_SSHD_JAIL_ACTIVE=%s\n' "$(fail2ban-client status sshd >/dev/null 2>&1 && echo 1 || echo 0)"
  printf 'SSH_PORT=%s\n' "$port"
  printf 'FAIL2BAN_BACKEND=%s\n' "$backend"
  printf 'REALITY_METADATA_RULE_ACTIVE=%s\n' "$rule"
  printf 'RETENTION_DAYS=%s\n' "${retention:-UNSET}"
  echo 'RAW_PROXY_ACCESS_LOG=DISABLED'
  echo 'TNA_SECURITY_BASELINE_STATUS_END'
}

remove_baseline() {
  require_root
  if [ -x "$FIREWALL_HELPER" ] && grep -Fqx "$HELPER_MARKER" "$FIREWALL_HELPER" 2>/dev/null; then
    "$FIREWALL_HELPER" stop || true
  fi
  systemctl disable --now text-node-assistant-security-firewall.service >/dev/null 2>&1 || true
  grep -Fqx "$JAIL_MARKER" "$JAIL_FILE" 2>/dev/null && rm -f "$JAIL_FILE"
  grep -Fqx "$HELPER_MARKER" "$FIREWALL_HELPER" 2>/dev/null && rm -f "$FIREWALL_HELPER"
  grep -Fqx "$UNIT_MARKER" "$FIREWALL_UNIT" 2>/dev/null && rm -f "$FIREWALL_UNIT"
  grep -Fqx "$LOGROTATE_MARKER" "$LOGROTATE_FILE" 2>/dev/null && rm -f "$LOGROTATE_FILE"
  rm -f "$STATE_FILE"
  systemctl daemon-reload
  if command -v fail2ban-client >/dev/null 2>&1 && systemctl is-active --quiet fail2ban; then
    fail2ban-client reload >/dev/null 2>&1 || systemctl restart fail2ban >/dev/null 2>&1 || true
  fi
  echo 'TNA_SECURITY_BASELINE_REMOVED'
  echo 'FAIL2BAN_PACKAGE_PRESERVED=1'
}

case "$MODE" in
  --status|status) status_baseline ;;
  --apply|apply) apply_baseline ;;
  --remove|remove) remove_baseline ;;
  *) die USAGE 2 ;;
esac
