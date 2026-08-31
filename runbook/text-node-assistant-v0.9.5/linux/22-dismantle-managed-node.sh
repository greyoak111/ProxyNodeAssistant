#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

MODE="${1:---plan}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BASELINE_ROOT="/root/.config/proxy-runbook/original-baseline-v1"
BASELINE_FILES="$BASELINE_ROOT/files"
LEDGER="$BASELINE_ROOT/ledger.env"
PUBLIC_ENV="/etc/proxy-runbook/public.env"
TNA_STATE_ROOT="/etc/text-node-assistant"
TNA_RUNTIME_ROOT="/root/.config/text-node-assistant"
TNA_VAR_ROOT="/var/lib/text-node-assistant"

managed_paths=(
  /etc/x-ui
  /usr/local/x-ui
  /etc/systemd/system/x-ui.service
  /etc/nginx
  /etc/letsencrypt
  /etc/ufw
  /etc/fail2ban
  /etc/network/interfaces
  /etc/netplan
  /etc/sysctl.conf
  /etc/sysctl.d
  /etc/apt/sources.list.d/cloudflare-client.list
  /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg
  /var/lib/cloudflare-warp
  /etc/systemd/system/nginx.service.d
  /etc/systemd/system/proxy-runbook-zram.service
  /etc/systemd/system/text-node-assistant-zram.service
  /etc/text-node-assistant
  /root/.config/text-node-assistant
  /var/lib/text-node-assistant
  /var/www/cover
  /var/log/nginx/text-node-assistant-security.log
)

owned_packages=(
  nginx
  nginx-common
  nginx-core
  nginx-full
  nginx-light
  nginx-extras
  certbot
  python3-certbot-nginx
  fail2ban
  cloudflare-warp
  vnstat
)

owned_services=(nginx fail2ban warp-svc vnstat x-ui proxy-runbook-zram.service text-node-assistant-zram.service)

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

is_installed() {
  dpkg-query -W -f='${db:Status-Abbrev}' "$1" 2>/dev/null | grep -q '^ii'
}

bool_line() {
  if "$@"; then printf '1'; else printf '0'; fi
}

copy_baseline_path() {
  local path="$1"
  [ -e "$path" ] || [ -L "$path" ] || return 0
  (cd / && cp -a --parents "${path#/}" "$BASELINE_FILES/")
}

ledger_value() {
  local key="$1"
  sed -n "s/^${key}=//p" "$LEDGER" 2>/dev/null | sed -n '1p'
}

baseline_ledger_is_valid() {
  local mode
  [ -f "$LEDGER" ] && [ ! -L "$LEDGER" ] || return 1
  [ "$(ledger_value LEDGER_VERSION)" = "1" ] || return 1
  mode="$(ledger_value BASELINE_MODE)"
  case "$mode" in
    EXACT|LEGACY_UNCERTAIN) return 0 ;;
    *) return 1 ;;
  esac
}

assert_baseline_ledger_safe() {
  if [ -e "$LEDGER" ] || [ -L "$LEDGER" ]; then
    baseline_ledger_is_valid || \
      die "existing original-baseline ledger is malformed; refusing to downgrade to an uncertain dismantle"
  fi
}

capture_baseline() {
  if [ -e "$LEDGER" ] || [ -L "$LEDGER" ]; then
    baseline_ledger_is_valid || \
      die "existing original-baseline ledger is malformed; preserve it and repair or restore it before continuing"
    echo "ORIGINAL_BASELINE_ALREADY_CAPTURED"
    return 0
  fi

  if [ -e "$BASELINE_ROOT" ] || [ -L "$BASELINE_ROOT" ]; then
    [ -d "$BASELINE_ROOT" ] && [ ! -L "$BASELINE_ROOT" ] || \
      die "original-baseline root is not a safe directory"
    # A missing ledger means an earlier capture never committed.  Discard only
    # its tool-owned partial file snapshot before starting a fresh capture.
    rm -rf -- "$BASELINE_FILES"
  fi
  install -d -m 700 "$BASELINE_ROOT"
  if [ -s "$PUBLIC_ENV" ] || [ -e /var/www/cover/.proxy-runbook-cover ] || \
     [ -e /etc/sysctl.d/99-proxy-runbook-performance.conf ]; then
    {
      echo 'LEDGER_VERSION=1'
      echo 'BASELINE_MODE=LEGACY_UNCERTAIN'
      printf 'CAPTURED_AT=%s\n' "$(date -Is)"
    } > "$LEDGER"
    chmod 600 "$LEDGER"
    echo "ORIGINAL_BASELINE_LEGACY_UNCERTAIN"
    return 0
  fi

  install -d -m 700 "$BASELINE_FILES"
  local path package service tmp
  for path in "${managed_paths[@]}"; do
    copy_baseline_path "$path"
  done
  tmp="$(mktemp)"
  {
    echo 'LEDGER_VERSION=1'
    echo 'BASELINE_MODE=EXACT'
    printf 'CAPTURED_AT=%s\n' "$(date -Is)"
    for package in "${owned_packages[@]}"; do
      printf 'PACKAGE_%s_PRESENT=%s\n' "${package//-/_}" "$(bool_line is_installed "$package")"
    done
    for service in "${owned_services[@]}"; do
      printf 'SERVICE_%s_ENABLED=%s\n' "${service//[-.]/_}" \
        "$(bool_line systemctl is-enabled --quiet "$service")"
      printf 'SERVICE_%s_ACTIVE=%s\n' "${service//[-.]/_}" \
        "$(bool_line systemctl is-active --quiet "$service")"
    done
    printf 'UFW_ACTIVE=%s\n' "$(ufw status 2>/dev/null | grep -q '^Status: active' && echo 1 || echo 0)"
  } > "$tmp"
  install -m 600 "$tmp" "$LEDGER"
  rm -f "$tmp"
  echo "ORIGINAL_BASELINE_CAPTURED_EXACT"
}

baseline_mode() {
  ledger_value BASELINE_MODE
}

print_presence() {
  local label="$1"; shift
  if "$@" >/dev/null 2>&1; then printf '%s=1\n' "$label"; else printf '%s=0\n' "$label"; fi
}

plan() {
  local grade
  assert_baseline_ledger_safe
  grade="$(baseline_mode)"
  [ -n "$grade" ] || grade="LEGACY_UNCERTAIN"
  echo "PNA_DISMANTLE_PLAN_BEGIN"
  printf 'RESTORE_GRADE=%s\n' "$grade"
  print_presence HAS_XUI test -e /usr/local/x-ui
  print_presence HAS_NGINX command -v nginx
  print_presence HAS_WARP command -v warp-cli
  print_presence HAS_FAIL2BAN command -v fail2ban-client
  print_presence HAS_VNSTAT command -v vnstat
  print_presence HAS_COVER test -e /var/www/cover
  if [ -e /opt/text-node-assistant-current ] || [ -L /opt/text-node-assistant-current ] || \
     [ -e /opt/proxy-runbook-current ] || [ -L /opt/proxy-runbook-current ]; then
    echo 'HAS_TOOLKIT=1'
  else
    echo 'HAS_TOOLKIT=0'
  fi
  echo "PRESERVE_SSH_ACCESS=1"
  echo "PRESERVE_SHARED_BASE_PACKAGES=1"
  echo "DOWNLOAD_RESCUE_BEFORE_EXECUTE=REQUIRED"
  if [ "$grade" = "EXACT" ]; then
    echo "ACTION=RESTORE_CAPTURED_BASELINE"
  else
    echo "ACTION=LEGACY_FULL_REMOVE_TOOL_OWNED_NODE_STACK"
    echo "WARNING=NO_PRE_INSTALL_BASELINE_AVAILABLE"
  fi
  echo "PNA_DISMANTLE_PLAN_END"
}

remove_known_ufw_rules() {
  local number
  # Exact legacy rules are removed by specification first; UFW deletes the
  # corresponding IPv4/IPv6 pair while preserving the SSH rule.
  ufw --force delete allow 80/tcp >/dev/null 2>&1 || true
  ufw --force delete allow 443/tcp >/dev/null 2>&1 || true
  ufw --force delete allow 8443/tcp >/dev/null 2>&1 || true
  ufw --force delete allow 24443/tcp >/dev/null 2>&1 || true
  # Then remove any source-scoped/commented runbook test rules by number.
  while :; do
    number="$(ufw status numbered 2>/dev/null \
      | grep -E 'proxy-runbook|text-node-assistant|TNA-' \
      | sed -n 's/^\[[[:space:]]*\([0-9]\+\)\].*/\1/p' \
      | sort -rn | sed -n '1p')"
    [ -n "$number" ] || break
    yes | ufw delete "$number" >/dev/null 2>&1 || break
  done
}

remove_current_stack() {
  local domain="" package purge_packages=() candidate cert_domains=()

  # A half-finished CDN switch may have changed x-ui, Nginx and UFW together.
  # Roll it back first so dismantling always starts from a coherent topology.
  if [ -d "$TNA_RUNTIME_ROOT/cdn-route-transaction" ] && [ -x "$ROOT/linux/28-topology-reconcile.sh" ]; then
    bash "$ROOT/linux/28-topology-reconcile.sh" --rollback-pending || \
      die "pending CDN transaction could not be rolled back safely"
  fi
  if [ -x "$ROOT/linux/05f-cloudflare-origin-lock.sh" ]; then
    bash "$ROOT/linux/05f-cloudflare-origin-lock.sh" remove >/dev/null 2>&1 || \
      die "managed Cloudflare origin-lock rules could not be removed safely"
  fi

  # Only certificate names recorded by this product are candidates for
  # deletion.  Never enumerate and delete unrelated Certbot identities.
  for candidate in \
    "$(sed -n 's/^COVER_DOMAIN=//p' "$PUBLIC_ENV" 2>/dev/null | sed -n '1p')" \
    "$(sed -n 's/^ORANGE_DOMAIN=//p' "$TNA_RUNTIME_ROOT/topology.env" 2>/dev/null | sed -n '1p')" \
    "$(sed -n 's/^GRAY_DOMAIN=//p' "$TNA_RUNTIME_ROOT/topology.env" 2>/dev/null | sed -n '1p')"; do
    [[ "$candidate" =~ ^([A-Za-z0-9][A-Za-z0-9-]*\.)+[A-Za-z]{2,63}$ ]] || continue
    case " ${cert_domains[*]:-} " in *" $candidate "*) ;; *) cert_domains+=("$candidate");; esac
  done
  if command -v certbot >/dev/null 2>&1; then
    for domain in "${cert_domains[@]}"; do
      [ -n "$domain" ] || continue
      certbot delete --cert-name "$domain" --non-interactive >/dev/null 2>&1 || true
    done
  fi

  for service in "${owned_services[@]}"; do
    systemctl disable --now "$service" >/dev/null 2>&1 || true
  done
  if command -v warp-cli >/dev/null 2>&1; then
    warp-cli --accept-tos disconnect >/dev/null 2>&1 || warp-cli disconnect >/dev/null 2>&1 || true
    warp-cli --accept-tos registration delete >/dev/null 2>&1 || true
  fi
  for device in $(swapon --noheadings --show=NAME 2>/dev/null | grep '^/dev/zram' || true); do
    swapoff "$device" >/dev/null 2>&1 || true
    zramctl --reset "$device" >/dev/null 2>&1 || true
  done

  rm -rf -- /etc/x-ui /usr/local/x-ui
  rm -f -- /etc/systemd/system/x-ui.service

  if [ "$(baseline_mode)" = "EXACT" ]; then
    for package in "${owned_packages[@]}"; do
      if [ "$(ledger_value "PACKAGE_${package//-/_}_PRESENT")" != "1" ] && is_installed "$package"; then
        purge_packages+=("$package")
      fi
    done
  else
    for package in "${owned_packages[@]}"; do
      is_installed "$package" && purge_packages+=("$package")
    done
  fi
  if [ "${#purge_packages[@]}" -gt 0 ]; then
    DEBIAN_FRONTEND=noninteractive apt-get purge -y "${purge_packages[@]}"
  fi

  rm -rf -- /var/www/cover
  rm -f -- /etc/nginx/sites-enabled/cover /etc/nginx/sites-available/cover
  rm -f -- /etc/nginx/sites-enabled/proxy-cover /etc/nginx/sites-available/proxy-cover
  rm -f -- /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh
  rm -f -- /etc/apt/sources.list.d/cloudflare-client.list
  rm -f -- /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg
  rm -rf -- /var/lib/cloudflare-warp
  rm -f -- /etc/sysctl.d/99-proxy-runbook.conf /etc/sysctl.d/99-proxy-runbook-performance.conf
  rm -f -- /etc/systemd/system/proxy-runbook-zram.service
  rm -f -- /etc/systemd/system/text-node-assistant-zram.service
  rm -f -- /etc/systemd/system/x-ui.service.d/90-proxy-runbook-performance.conf
  rm -f -- /etc/systemd/system/nginx.service.d/90-proxy-runbook-performance.conf
  rm -f -- /etc/nginx/sites-enabled/tna-cdn-xhttp-stage /etc/nginx/sites-available/tna-cdn-xhttp-stage
  rm -f -- /etc/nginx/conf.d/text-node-assistant-security-log.conf
  rm -f -- /var/log/nginx/text-node-assistant-security.log
  remove_known_ufw_rules
}

restore_baseline_path() {
  local path="$1" source="$BASELINE_FILES/${1#/}"
  rm -rf -- "$path"
  if [ -e "$source" ] || [ -L "$source" ]; then
    mkdir -p "$(dirname "$path")"
    cp -a "$source" "$path"
  fi
}

restore_exact_baseline() {
  local path service enabled active
  for path in "${managed_paths[@]}"; do
    restore_baseline_path "$path"
  done
  systemctl daemon-reload
  for service in "${owned_services[@]}"; do
    enabled="$(ledger_value "SERVICE_${service//[-.]/_}_ENABLED")"
    active="$(ledger_value "SERVICE_${service//[-.]/_}_ACTIVE")"
    if [ "$enabled" = "1" ]; then systemctl enable "$service" >/dev/null 2>&1 || true
    else systemctl disable "$service" >/dev/null 2>&1 || true; fi
    if [ "$active" = "1" ]; then systemctl start "$service" >/dev/null 2>&1 || true
    else systemctl stop "$service" >/dev/null 2>&1 || true; fi
  done
  if command -v ufw >/dev/null 2>&1; then
    if [ "$(ledger_value UFW_ACTIVE)" = "1" ]; then ufw --force enable >/dev/null 2>&1 || true
    else ufw --force disable >/dev/null 2>&1 || true; fi
  fi
}

remove_tool_data_last() {
  rm -rf -- /root/proxy-runbook-livefix-backups /root/proxy-runbook-performance-backups
  rm -f -- \
    /root/proxy-node-backup-*.tar.gz /root/proxy-node-current-config-*.tar.gz \
    /root/text-node-backup-*.tar.gz /root/text-node-current-config-*.tar.gz
  if [ "$(baseline_mode)" != "EXACT" ]; then
    rm -rf -- /root/x-ui-backup-*
  fi
  rm -f -- /root/nginx-cover-before-*.conf /root/cover-nginx-before-v*.conf
  rm -f -- /root/proxy-node-client-link.txt
  for launcher in /usr/local/sbin/text-node /usr/local/bin/text-node; do
    if [ -f "$launcher" ] && [ ! -L "$launcher" ] && \
       grep -qF '/opt/text-node-assistant-current/linux/13-maintenance-menu.sh' "$launcher"; then
      rm -f -- "$launcher"
    elif [ -e "$launcher" ] || [ -L "$launcher" ]; then
      printf 'PRESERVED_UNMANAGED_LAUNCHER=%s\n' "$launcher"
    fi
  done
  for launcher in /usr/local/sbin/proxy-node /usr/local/bin/proxy-node; do
    if [ -f "$launcher" ] && [ ! -L "$launcher" ] && \
       grep -Eq '/usr/local/sbin/text-node|/opt/proxy-runbook-current/linux/13-maintenance-menu.sh' "$launcher"; then
      rm -f -- "$launcher"
    elif [ -e "$launcher" ] || [ -L "$launcher" ]; then
      printf 'PRESERVED_UNMANAGED_LAUNCHER=%s\n' "$launcher"
    fi
  done
  rm -f -- /opt/text-node-assistant-current /opt/proxy-runbook-current
  rm -rf -- /opt/text-node-assistant-v0.9.5
  rm -rf -- \
    /opt/proxy-runbook-v0.5 /opt/proxy-runbook-v0.6 /opt/proxy-runbook-v0.6.1 \
    /opt/proxy-runbook-v0.6.2 /opt/proxy-runbook-v0.6.3 /opt/proxy-runbook-v0.6.4 \
    /opt/proxy-runbook-v0.6.5 /opt/proxy-runbook-v0.6.6 /opt/proxy-runbook-v0.6.7 \
    /opt/proxy-runbook-v0.6.8 /opt/proxy-runbook-v0.6.9 /opt/proxy-runbook-v0.7.0 \
    /opt/proxy-runbook-v0.7.1 /opt/proxy-runbook-v0.7.2 /opt/proxy-runbook-v0.7.3 \
    /opt/proxy-runbook-v0.7.4 /opt/proxy-runbook-v0.7.5 /opt/proxy-runbook-v0.8.0 \
    /opt/proxy-runbook-v0.8.1 /opt/proxy-runbook-v0.8.2 /opt/proxy-runbook-v0.8.3 \
    /opt/proxy-runbook-v0.9.0
  rm -f -- /tmp/proxy-runbook-toolkit-v0.5.tar.gz /tmp/proxy-runbook-toolkit-v0.6.tar.gz
  rm -f -- /tmp/proxy-runbook-toolkit-v0.6.*.tar.gz /tmp/proxy-runbook-toolkit-v0.7.*.tar.gz
  rm -f -- /tmp/proxy-runbook-toolkit-v0.8.*.tar.gz /tmp/proxy-runbook-toolkit-v0.9.0.tar.gz
  rm -f -- /tmp/text-node-assistant-toolkit-v0.9.5.tar.gz
  rm -f -- /run/lock/text-node-assistant-deployment.lock

  # Exact restoration already removed new product state that did not exist at
  # baseline and restored any pre-existing path byte-for-byte.  Do not erase a
  # restored pre-existing directory a second time.  Legacy nodes have no such
  # baseline and therefore remove only the known product state roots here.
  if [ "$(baseline_mode)" != "EXACT" ]; then
    rm -rf -- "$TNA_STATE_ROOT" "$TNA_RUNTIME_ROOT" "$TNA_VAR_ROOT"
  fi
  rm -rf -- /etc/proxy-runbook /root/.config/proxy-runbook
}

execute_dismantle() {
  [ "${PNA_DISMANTLE_CONFIRM:-}" = "RESTORE_ORIGINAL" ] || die "missing exact dismantle confirmation"
  local grade
  assert_baseline_ledger_safe
  grade="$(baseline_mode)"
  [ -n "$grade" ] || grade="LEGACY_UNCERTAIN"
  if [ "$grade" != "EXACT" ] && [ "${PNA_LEGACY_FULL:-0}" != "1" ]; then
    die "legacy node has no pre-install baseline; explicit legacy-full authorization is required"
  fi
  [ -n "${SSH_CONNECTION:-}" ] || die "refusing to dismantle without a live SSH session"

  echo "PNA_DISMANTLE_BEGIN"
  printf 'RESTORE_GRADE=%s\n' "$grade"
  echo "SSH_ACCESS_PRESERVED=1"
  remove_current_stack
  if [ "$grade" = "EXACT" ]; then
    restore_exact_baseline
    echo "EXACT_BASELINE_RESTORED=1"
  else
    systemctl daemon-reload
    sysctl --system >/dev/null 2>&1 || true
    echo "LEGACY_TOOL_OWNED_STACK_REMOVED=1"
  fi

  echo "PRESERVED_SHARED_BASE_PACKAGES=1"
  echo "PRESERVED_SSH_CONFIGURATION=1"
  remove_tool_data_last

  [ ! -e /opt/text-node-assistant-current ] && [ ! -L /opt/text-node-assistant-current ]
  [ ! -e /opt/proxy-runbook-current ] && [ ! -L /opt/proxy-runbook-current ]
  [ ! -e /etc/proxy-runbook ]
  [ ! -e /root/.config/proxy-runbook ]
  if [ "$grade" != "EXACT" ]; then
    [ ! -e "$TNA_STATE_ROOT" ]
    [ ! -e "$TNA_RUNTIME_ROOT" ]
    [ ! -e "$TNA_VAR_ROOT" ]
  fi
  if [ "$grade" != "EXACT" ]; then
    [ ! -e /usr/local/x-ui ]
    ! systemctl is-active --quiet x-ui 2>/dev/null
    ! systemctl is-active --quiet nginx 2>/dev/null
    ! systemctl is-active --quiet warp-svc 2>/dev/null
    if ss -lnt 2>/dev/null | grep -E ':(80|443|8443|24443|40000)[[:space:]]' >/dev/null; then
      echo "ERROR: managed listener remains after legacy dismantle" >&2
      exit 9
    fi
    echo "LEGACY_MANAGED_LISTENERS_ABSENT=1"
  fi

  echo "PNA_DISMANTLE_END"
}

[ "$(id -u)" -eq 0 ] || die "run as root"

case "$MODE" in
  --capture-baseline) capture_baseline ;;
  --plan) plan ;;
  --execute) execute_dismantle ;;
  *) die "usage: $0 {--capture-baseline|--plan|--execute}" ;;
esac
