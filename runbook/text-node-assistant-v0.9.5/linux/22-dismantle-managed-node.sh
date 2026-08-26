#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

MODE="${1:---plan}"
TARGET="${2:-}"
BASELINE_ROOT="/root/.config/text-node-assistant/original-baseline-v1"
BASELINE_FILES="$BASELINE_ROOT/files"
LEDGER="$BASELINE_ROOT/ledger.env"
PUBLIC_ENV="/etc/text-node-assistant/public.env"
DRIVE_STATE="/etc/text-node-assistant/private-drive.env"
REMOVAL_ROOT="/root/.config/text-node-assistant/removal-v1"
REMOVAL_LEDGER="$REMOVAL_ROOT/ledger.env"
TOPOLOGY_ENV="/root/.config/text-node-assistant/topology.env"

proxy_baseline_paths=(
  /etc/x-ui
  /usr/local/x-ui
  /etc/systemd/system/x-ui.service
  /etc/nginx
  /etc/letsencrypt
  /etc/ufw
  /var/lib/cloudflare-warp
  /etc/systemd/system/nginx.service.d
  /etc/systemd/system/text-node-assistant-zram.service
)

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
  /etc/systemd/system/text-node-assistant-zram.service
  /etc/text-node-assistant
  /opt/text-node-assistant/copyparty
  /srv/text-node-assistant/drive-data
  /var/lib/text-node-assistant/copyparty
  /var/log/text-node-assistant/copyparty
  /etc/systemd/system/text-node-assistant-copyparty.service
  /usr/local/lib/text-node-assistant/security-firewall.sh
  /etc/systemd/system/text-node-assistant-security-firewall.service
  /etc/logrotate.d/text-node-assistant-security
  /etc/nginx/conf.d/text-node-assistant-security-log.conf
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
  cloudflare-warp
  vnstat
)

owned_services=(nginx warp-svc vnstat x-ui text-node-assistant-zram.service text-node-assistant-copyparty.service text-node-assistant-security-firewall.service)

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

drive_value() {
  local key="$1"
  sed -n "s/^${key}=//p" "$DRIVE_STATE" 2>/dev/null | sed -n '1p'
}

proxy_present() {
  local lifecycle
  lifecycle="$(drive_value NODE_LIFECYCLE_STATE || true)"
  [ -s /etc/text-node-assistant/deployment-state.env ] || [ -s "$TOPOLOGY_ENV" ] || \
    [ -e /var/www/cover/.text-node-assistant-cover ] || \
    [ -e /etc/nginx/sites-available/tna-cdn-xhttp-stage ] || \
    [[ "$lifecycle" =~ ^MANAGED_(GRAY|ORANGE|DUAL)_WITH_DRIVE$ ]] || \
    { [ "$lifecycle" != PROXY_REMOVED_DRIVE_RETAINED ] && { [ -e /usr/local/x-ui ] || [ -e /etc/x-ui ]; }; }
}

drive_present() {
  [ -s "$DRIVE_STATE" ] && [ -s /etc/text-node-assistant/drive-accounts.tsv ] && \
    [ -d /srv/text-node-assistant/drive-data ] && \
    [ -e /etc/systemd/system/text-node-assistant-copyparty.service ]
}

removal_value() {
  local key="$1"
  sed -n "s/^${key}=//p" "$REMOVAL_LEDGER" 2>/dev/null | sed -n '1p'
}

write_removal_ledger() {
  local transaction_id="$1" mode="$2" status="$3" removed="$4" preserved="$5"
  local data_export="$6" baseline_result="$7" tmp
  install -d -m 700 "$REMOVAL_ROOT"
  tmp="$(mktemp "$REMOVAL_ROOT/.ledger.XXXXXX")"
  {
    echo 'REMOVAL_SCHEMA_VERSION=1'
    printf 'REMOVAL_TRANSACTION_ID=%s\n' "$transaction_id"
    printf 'REMOVAL_MODE=%s\n' "$mode"
    printf 'REMOVAL_STATUS=%s\n' "$status"
    printf 'REMOVED_RESOURCE_IDS=%s\n' "$removed"
    printf 'PRESERVED_RESOURCE_IDS=%s\n' "$preserved"
    printf 'DATA_EXPORT_RESULT=%s\n' "$data_export"
    printf 'BASELINE_RESTORE_RESULT=%s\n' "$baseline_result"
    printf 'LAST_VERIFIED_AT=%s\n' "$(date -Is)"
  } > "$tmp"
  chmod 600 "$tmp"
  mv -f -- "$tmp" "$REMOVAL_LEDGER"
}

dismantle_status() {
  local lifecycle proxy=0 drive=0 removal_status removal_mode
  proxy_present && proxy=1
  drive_present && drive=1
  lifecycle="$(drive_value NODE_LIFECYCLE_STATE || true)"
  removal_status="$(removal_value REMOVAL_STATUS || true)"
  removal_mode="$(removal_value REMOVAL_MODE || true)"
  [ -n "$lifecycle" ] || lifecycle=BASELINE_UNMANAGED
  [ -n "$removal_status" ] || removal_status=NONE
  [ -n "$removal_mode" ] || removal_mode=NONE
  echo 'TNA_DISMANTLE_STATUS_BEGIN'
  printf 'PROXY_PRESENT=%s\nDRIVE_PRESENT=%s\nNODE_LIFECYCLE_STATE=%s\n' "$proxy" "$drive" "$lifecycle"
  printf 'REMOVAL_STATUS=%s\nREMOVAL_MODE=%s\n' "$removal_status" "$removal_mode"
  if [ "$proxy" = 1 ] && [ "$drive" = 1 ]; then
    echo 'LEGAL_ACTIONS=PROXY_ONLY,FULL_BASELINE'
  elif [ "$proxy" = 0 ] && [ "$drive" = 1 ] && [ "$lifecycle" = PROXY_REMOVED_DRIVE_RETAINED ]; then
    echo 'LEGAL_ACTIONS=REMAINING_DRIVE'
  elif [ "$proxy" = 0 ] && [ "$drive" = 0 ]; then
    echo 'LEGAL_ACTIONS=NONE'
  else
    echo 'LEGAL_ACTIONS=RECOVER_IN_MENU_1'
  fi
  echo 'TNA_DISMANTLE_STATUS_END'
}

capture_baseline() {
  if [ -s "$LEDGER" ]; then
    echo "ORIGINAL_BASELINE_ALREADY_CAPTURED"
    return 0
  fi

  install -d -m 700 "$BASELINE_ROOT"
  if [ -s "$PUBLIC_ENV" ] || [ -e /var/www/cover/.text-node-assistant-cover ] || \
     [ -e /etc/sysctl.d/99-text-node-assistant-performance.conf ]; then
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
  local requested="${1:-full}" grade lifecycle file_count=0 data_bytes=0 legal removal_mode
  grade="$(baseline_mode)"
  [ -n "$grade" ] || grade="LEGACY_UNCERTAIN"
  lifecycle="$(drive_value NODE_LIFECYCLE_STATE || true)"
  legal="$(dismantle_status | sed -n 's/^LEGAL_ACTIONS=//p')"
  case "$requested" in
    proxy-only) [[ ",$legal," == *,PROXY_ONLY,* ]] || die "proxy-only is not legal in the current node state"; removal_mode=PROXY_ONLY ;;
    full) [[ ",$legal," == *,FULL_BASELINE,* ]] || die "full baseline removal is not legal in the current node state"; removal_mode=FULL_BASELINE ;;
    remaining-drive) [ "$legal" = REMAINING_DRIVE ] || die "remaining-drive removal is not legal in the current node state"; removal_mode=REMAINING_DRIVE ;;
    *) die "invalid dismantle plan mode" ;;
  esac
  if [ -d /srv/text-node-assistant/drive-data ]; then
    file_count="$(find /srv/text-node-assistant/drive-data -type f -printf . 2>/dev/null | wc -c)"
    data_bytes="$(find /srv/text-node-assistant/drive-data -type f -printf '%s\n' 2>/dev/null | awk '{sum+=$1} END{printf "%.0f",sum+0}')"
  fi
  echo "TNA_DISMANTLE_PLAN_BEGIN"
  printf 'REMOVAL_MODE=%s\n' "$removal_mode"
  printf 'RESTORE_GRADE=%s\n' "$grade"
  printf 'NODE_LIFECYCLE_STATE=%s\n' "${lifecycle:-UNKNOWN}"
  print_presence HAS_XUI test -e /usr/local/x-ui
  print_presence HAS_NGINX command -v nginx
  print_presence HAS_WARP command -v warp-cli
  print_presence HAS_FAIL2BAN command -v fail2ban-client
  print_presence HAS_VNSTAT command -v vnstat
  print_presence HAS_COVER test -e /var/www/cover
  print_presence HAS_TOOLKIT test -e /opt/text-node-assistant-current
  print_presence HAS_PRIVATE_DRIVE_DATA test -e /srv/text-node-assistant/drive-data
  print_presence HAS_COPYPARTY_SERVICE test -e /etc/systemd/system/text-node-assistant-copyparty.service
  printf 'DRIVE_DATA_ROOT=/srv/text-node-assistant/drive-data\n'
  printf 'DRIVE_FILE_COUNT=%s\nDRIVE_DATA_BYTES=%s\n' "$file_count" "$data_bytes"
  echo "PRESERVE_SSH_ACCESS=1"
  echo "PRESERVE_SHARED_BASE_PACKAGES=1"
  echo "DOWNLOAD_RESCUE_BEFORE_EXECUTE=REQUIRED"
  case "$requested" in
    proxy-only)
      echo 'ACTION=REMOVE_PROXY_RETAIN_DRIVE'
      echo 'REMOVED_RESOURCE_IDS=PROXY_XUI,PROXY_INBOUNDS,PROXY_NGINX,PROXY_CERTIFICATES,PROXY_WARP,PROXY_FIREWALL,PROXY_COVER'
      echo 'PRESERVED_RESOURCE_IDS=DRIVE_SERVICE,DRIVE_DATA,DRIVE_ACCOUNTS,DRIVE_ESCROW,DEVICE_REGISTRY,SSH_ACCESS,TOOLKIT,ORIGINAL_BASELINE'
      ;;
    full|remaining-drive)
      echo 'ACTION=RESTORE_CAPTURED_BASELINE'
      echo 'REMOVED_RESOURCE_IDS=ALL_TNA_PROXY,ALL_TNA_DRIVE,DRIVE_DATA,DRIVE_ESCROW,DEVICE_REGISTRY,TOOLKIT,TNA_STATE'
      echo 'PRESERVED_RESOURCE_IDS=SSH_RECOVERY,SHARED_BASE_PACKAGES,DOWNLOADED_RESCUE'
      [ "$grade" = EXACT ] || echo 'WARNING=NO_PRE_INSTALL_BASELINE_AVAILABLE'
      ;;
  esac
  echo "TNA_DISMANTLE_PLAN_END"
}

remove_known_ufw_rules() {
  local number
  # Ambiguous unlabelled 80/443 rules may belong to the user. Only rules with
  # an explicit TNA/legacy-runbook ownership comment are removed here; exact
  # installations restore the captured /etc/ufw baseline instead.
  while :; do
    number="$(ufw status numbered 2>/dev/null \
      | grep -Ei 'text-node-assistant|proxy-node-assistant|proxy-runbook|reality-shadow' \
      | sed -n 's/^\[[[:space:]]*\([0-9]\+\)\].*/\1/p' \
      | sort -rn | sed -n '1p')"
    [ -n "$number" ] || break
    yes | ufw delete "$number" >/dev/null 2>&1 || break
  done
}

remove_managed_certificates() {
  local domain
  command -v certbot >/dev/null 2>&1 || return 0
  {
    sed -n 's/^GRAY_DOMAIN=//p; s/^ORANGE_DOMAIN=//p' "$TOPOLOGY_ENV" 2>/dev/null || true
    sed -n 's/^COVER_DOMAIN=//p' "$PUBLIC_ENV" 2>/dev/null || true
  } | awk 'NF && !seen[$0]++' | while IFS= read -r domain; do
    [[ "$domain" =~ ^([A-Za-z0-9][A-Za-z0-9-]*\.)+[A-Za-z]{2,63}$ ]] || continue
    certbot delete --cert-name "$domain" --non-interactive >/dev/null 2>&1 || true
  done
}

remove_proxy_stack_preserve_drive() {
  local path
  if [ -x /opt/text-node-assistant-current/linux/24-security-baseline.sh ]; then
    bash /opt/text-node-assistant-current/linux/24-security-baseline.sh --remove || true
  fi
  remove_managed_certificates
  systemctl disable --now x-ui >/dev/null 2>&1 || true
  systemctl disable --now warp-svc >/dev/null 2>&1 || true
  if command -v warp-cli >/dev/null 2>&1; then
    warp-cli --accept-tos disconnect >/dev/null 2>&1 || warp-cli disconnect >/dev/null 2>&1 || true
    warp-cli --accept-tos registration delete >/dev/null 2>&1 || true
  fi
  rm -rf -- /etc/x-ui /usr/local/x-ui
  rm -f -- /etc/systemd/system/x-ui.service
  rm -rf -- /var/www/cover
  rm -f -- /etc/nginx/sites-enabled/cover /etc/nginx/sites-available/cover
  rm -f -- /etc/nginx/sites-enabled/proxy-cover /etc/nginx/sites-available/proxy-cover
  rm -f -- /etc/nginx/sites-enabled/tna-cdn-xhttp-stage /etc/nginx/sites-available/tna-cdn-xhttp-stage
  rm -f -- /etc/nginx/conf.d/text-node-assistant-security-log.conf
  rm -f -- /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh
  rm -f -- /etc/apt/sources.list.d/cloudflare-client.list
  rm -f -- /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg
  rm -rf -- /var/lib/cloudflare-warp
  rm -f -- /etc/sysctl.d/99-text-node-assistant.conf /etc/sysctl.d/99-text-node-assistant-performance.conf
  rm -f -- /etc/systemd/system/text-node-assistant-zram.service
  rm -f -- /etc/systemd/system/x-ui.service.d/90-text-node-assistant-performance.conf
  rm -f -- /etc/systemd/system/nginx.service.d/90-text-node-assistant-performance.conf

  if [ "$(baseline_mode)" = EXACT ]; then
    for path in "${proxy_baseline_paths[@]}"; do restore_baseline_path "$path"; done
  else
    remove_known_ufw_rules
  fi

  rm -rf -- /etc/text-node-assistant/cloudflare /etc/text-node-assistant/candidates
  rm -f -- /etc/text-node-assistant/public.env /etc/text-node-assistant/deployment-state.env
  rm -f -- "$TOPOLOGY_ENV" /root/.config/text-node-assistant/cdn-xhttp.env
  if [ -r /root/.config/text-node-assistant/CURRENT-LOGIN-CREDENTIALS.env ]; then
    sed -i '/^PANEL_USERNAME=/d; /^PANEL_PASSWORD=/d' /root/.config/text-node-assistant/CURRENT-LOGIN-CREDENTIALS.env
  fi
  if [ -r /root/.config/text-node-assistant/HANDOFF-SECRETS.txt ]; then
    sed -i '/^PANEL_/d; /^REALITY_/d; /^CDN_/d; /^SUBSCRIPTION_/d' /root/.config/text-node-assistant/HANDOFF-SECRETS.txt
  fi
  systemctl daemon-reload
  nginx -t >/dev/null 2>&1 && systemctl reload nginx >/dev/null 2>&1 || true
  sysctl --system >/dev/null 2>&1 || true
}

execute_proxy_only() {
  [ "${TNA_DISMANTLE_CONFIRM:-}" = REMOVE_PROXY_KEEP_DRIVE ] || die "missing exact proxy-only confirmation"
  [ -n "${SSH_CONNECTION:-}" ] || die "refusing to dismantle without a live SSH session"
  proxy_present || die "managed proxy is not present"
  drive_present || die "mandatory drive is not intact"
  systemctl is-active --quiet text-node-assistant-copyparty.service || die "drive service is not active"
  local transaction_id="tna-remove-$(date -u +%Y%m%dT%H%M%SZ)-$(openssl rand -hex 6)"
  proxy_only_failed() {
    local rc="${1:-1}"
    trap - ERR
    set +e
    write_removal_ledger "$transaction_id" PROXY_ONLY FAILED_RECOVERABLE \
      'PARTIAL_PROXY_REMOVAL_REQUIRES_MENU_1_RECOVERY' \
      'DRIVE_DATA,DRIVE_ACCOUNTS,DRIVE_ESCROW,DEVICE_REGISTRY,SSH_ACCESS,TOOLKIT,ORIGINAL_BASELINE' \
      CONFIG_RESCUE_VERIFIED FAILED
    printf 'TNA_DISMANTLE_FAILED_RECOVERABLE=1\nREMOVAL_TRANSACTION_ID=%s\n' "$transaction_id" >&2
    exit "$rc"
  }
  trap 'proxy_only_failed $?' ERR
  write_removal_ledger "$transaction_id" PROXY_ONLY IN_PROGRESS \
    'PROXY_XUI,PROXY_INBOUNDS,PROXY_NGINX,PROXY_CERTIFICATES,PROXY_WARP,PROXY_FIREWALL,PROXY_COVER' \
    'DRIVE_SERVICE,DRIVE_DATA,DRIVE_ACCOUNTS,DRIVE_ESCROW,DEVICE_REGISTRY,SSH_ACCESS,TOOLKIT,ORIGINAL_BASELINE' \
    CONFIG_RESCUE_VERIFIED PENDING
  printf 'TNA_DISMANTLE_BEGIN\nREMOVAL_TRANSACTION_ID=%s\nREMOVAL_MODE=PROXY_ONLY\nSSH_ACCESS_PRESERVED=1\n' "$transaction_id"

  bash "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/29-copyparty-drive.sh" finalize-install PROXY_REMOVED_DRIVE_RETAINED >/dev/null
  remove_proxy_stack_preserve_drive

  ! proxy_present || proxy_only_failed 9
  drive_present && systemctl is-active --quiet text-node-assistant-copyparty.service || proxy_only_failed 9
  [ "$(drive_value NODE_LIFECYCLE_STATE)" = PROXY_REMOVED_DRIVE_RETAINED ] || proxy_only_failed 9
  [ "$(drive_value DRIVE_REGISTRATION_READY)" = 0 ] || proxy_only_failed 9
  write_removal_ledger "$transaction_id" PROXY_ONLY COMMITTED \
    'PROXY_XUI,PROXY_INBOUNDS,PROXY_NGINX,PROXY_CERTIFICATES,PROXY_WARP,PROXY_FIREWALL,PROXY_COVER' \
    'DRIVE_SERVICE,DRIVE_DATA,DRIVE_ACCOUNTS,DRIVE_ESCROW,DEVICE_REGISTRY,SSH_ACCESS,TOOLKIT,ORIGINAL_BASELINE' \
    CONFIG_RESCUE_VERIFIED NOT_REQUIRED
  trap - ERR
  printf 'PROXY_REMOVED=1\nDRIVE_PRESERVED=1\nNODE_LIFECYCLE_STATE=PROXY_REMOVED_DRIVE_RETAINED\nDRIVE_REGISTRATION_READY=0\n'
  printf 'PRESERVED_SHARED_BASE_PACKAGES=1\nPRESERVED_SSH_CONFIGURATION=1\nTNA_DISMANTLE_END\n'
}

remove_current_stack() {
  local domain=""
  if [ -x /opt/text-node-assistant-current/linux/24-security-baseline.sh ]; then
    bash /opt/text-node-assistant-current/linux/24-security-baseline.sh --remove || true
  elif [ -x /opt/text-node-assistant-v0.9.5/linux/24-security-baseline.sh ]; then
    bash /opt/text-node-assistant-v0.9.5/linux/24-security-baseline.sh --remove || true
  fi
  if [ -r "$PUBLIC_ENV" ]; then
    domain="$(sed -n 's/^COVER_DOMAIN=//p' "$PUBLIC_ENV" | sed -n '1p')"
  fi
  if [[ "$domain" =~ ^([A-Za-z0-9][A-Za-z0-9-]*\.)+[A-Za-z]{2,63}$ ]] && command -v certbot >/dev/null 2>&1; then
    certbot delete --cert-name "$domain" --non-interactive >/dev/null 2>&1 || true
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
  rm -f -- /etc/nginx/sites-enabled/tna-private-drive /etc/nginx/sites-available/tna-private-drive
  rm -rf -- /etc/text-node-assistant /opt/text-node-assistant/copyparty
  rm -rf -- /srv/text-node-assistant/drive-data /var/lib/text-node-assistant/copyparty /var/log/text-node-assistant/copyparty
  rm -f -- /etc/systemd/system/text-node-assistant-copyparty.service
  rm -f -- /var/log/nginx/text-node-assistant-security.log /var/log/nginx/text-node-assistant-security.log.*
  rm -f -- /etc/nginx/conf.d/text-node-assistant-security-log.conf

  # Shared packages are deliberately retained by default. Removing nginx,
  # certbot, fail2ban, vnstat, or their dependencies requires a separate,
  # explicit package-removal decision and is never folded into baseline restore.

  rm -rf -- /var/www/cover
  rm -f -- /etc/nginx/sites-enabled/cover /etc/nginx/sites-available/cover
  rm -f -- /etc/nginx/sites-enabled/proxy-cover /etc/nginx/sites-available/proxy-cover
  rm -f -- /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh
  rm -f -- /etc/apt/sources.list.d/cloudflare-client.list
  rm -f -- /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg
  rm -rf -- /var/lib/cloudflare-warp
  rm -f -- /etc/sysctl.d/99-text-node-assistant.conf /etc/sysctl.d/99-text-node-assistant-performance.conf
  rm -f -- /etc/systemd/system/text-node-assistant-zram.service
  rm -f -- /etc/systemd/system/x-ui.service.d/90-text-node-assistant-performance.conf
  rm -f -- /etc/systemd/system/nginx.service.d/90-text-node-assistant-performance.conf
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
  rm -rf -- /root/text-node-assistant-livefix-backups /root/text-node-assistant-performance-backups
  rm -f -- /root/text-node-backup-*.tar.gz /root/text-node-current-config-*.tar.gz
  if [ "$(baseline_mode)" != "EXACT" ]; then
    rm -rf -- /root/x-ui-backup-*
  fi
  rm -f -- /root/nginx-cover-before-*.conf /root/cover-nginx-before-v*.conf
  rm -f -- /root/text-node-client-link.txt
  rm -f -- /usr/local/sbin/text-node /usr/local/bin/text-node
  rm -f -- /opt/text-node-assistant-current
  rm -rf -- \
    /opt/text-node-assistant-v0.5 /opt/text-node-assistant-v0.6 /opt/text-node-assistant-v0.6.1 \
    /opt/text-node-assistant-v0.6.2 /opt/text-node-assistant-v0.6.3 /opt/text-node-assistant-v0.6.4 \
    /opt/text-node-assistant-v0.6.5 /opt/text-node-assistant-v0.6.6 /opt/text-node-assistant-v0.6.7 \
    /opt/text-node-assistant-v0.6.8 /opt/text-node-assistant-v0.6.9 /opt/text-node-assistant-v0.7.0 \
    /opt/text-node-assistant-v0.7.1 /opt/text-node-assistant-v0.7.2 /opt/text-node-assistant-v0.7.3 \
    /opt/text-node-assistant-v0.7.4 /opt/text-node-assistant-v0.7.5 /opt/text-node-assistant-v0.8.0 \
    /opt/text-node-assistant-v0.8.1 /opt/text-node-assistant-v0.8.2 /opt/text-node-assistant-v0.8.3 \
    /opt/text-node-assistant-v0.9.0 /opt/text-node-assistant-v0.9.5
  rm -f -- /tmp/text-node-assistant-toolkit-v0.5.tar.gz /tmp/text-node-assistant-toolkit-v0.6.tar.gz
  rm -f -- /tmp/text-node-assistant-toolkit-v0.6.*.tar.gz /tmp/text-node-assistant-toolkit-v0.7.*.tar.gz
  rm -f -- /tmp/text-node-assistant-toolkit-v0.8.*.tar.gz /tmp/text-node-assistant-toolkit-v0.9.0.tar.gz /tmp/text-node-assistant-toolkit-v0.9.5.tar.gz
  rm -rf -- /etc/text-node-assistant /root/.config/text-node-assistant
}

execute_dismantle() {
  local requested="${1:-full}" removal_mode transaction_id
  [ "${TNA_DISMANTLE_CONFIRM:-}" = "RESTORE_ORIGINAL" ] || die "missing exact dismantle confirmation"
  [ "${TNA_DATA_EXPORT_VERIFIED:-0}" = 1 ] || die "verified drive-data export is required"
  local grade="$(baseline_mode)"
  [ -n "$grade" ] || grade="LEGACY_UNCERTAIN"
  if [ "$grade" != "EXACT" ] && [ "${TNA_LEGACY_FULL:-0}" != "1" ]; then
    die "legacy node has no pre-install baseline; explicit legacy-full authorization is required"
  fi
  [ -n "${SSH_CONNECTION:-}" ] || die "refusing to dismantle without a live SSH session"
  case "$requested" in
    full)
      proxy_present && drive_present || die "full removal requires an intact managed proxy+drive node"
      removal_mode=FULL_BASELINE
      ;;
    remaining-drive)
      ! proxy_present || die "remaining-drive removal is forbidden while a proxy is present"
      drive_present || die "remaining drive is not intact"
      [ "$(drive_value NODE_LIFECYCLE_STATE)" = PROXY_REMOVED_DRIVE_RETAINED ] || die "remaining-drive lifecycle is invalid"
      removal_mode=REMAINING_DRIVE
      ;;
    *) die "invalid execute mode" ;;
  esac
  transaction_id="tna-remove-$(date -u +%Y%m%dT%H%M%SZ)-$(openssl rand -hex 6)"
  write_removal_ledger "$transaction_id" "$removal_mode" IN_PROGRESS \
    'ALL_TNA_PROXY,ALL_TNA_DRIVE,DRIVE_DATA,DRIVE_ESCROW,DEVICE_REGISTRY,TOOLKIT,TNA_STATE' \
    'SSH_RECOVERY,SHARED_BASE_PACKAGES,DOWNLOADED_RESCUE' VERIFIED PENDING

  echo "TNA_DISMANTLE_BEGIN"
  printf 'REMOVAL_TRANSACTION_ID=%s\nREMOVAL_MODE=%s\nDATA_EXPORT_RESULT=VERIFIED\n' "$transaction_id" "$removal_mode"
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
  [ ! -e /etc/text-node-assistant ]
  [ ! -e /root/.config/text-node-assistant ]
  if [ "$grade" != "EXACT" ]; then
    [ ! -e /usr/local/x-ui ]
    ! systemctl is-active --quiet x-ui 2>/dev/null
    ! systemctl is-active --quiet nginx 2>/dev/null
    ! systemctl is-active --quiet warp-svc 2>/dev/null
    if ss -lnt 2>/dev/null | grep -E ':(80|443|2053|2083|2087|2096|3923|8443|24443|40000)[[:space:]]' >/dev/null; then
      echo "ERROR: managed listener remains after legacy dismantle" >&2
      exit 9
    fi
    echo "LEGACY_MANAGED_LISTENERS_ABSENT=1"
  fi

  printf 'REMOVAL_STATUS=COMMITTED\nBASELINE_RESTORE_RESULT=%s\n' "$([ "$grade" = EXACT ] && printf EXACT_RESTORED || printf LEGACY_BOUNDED)"
  echo "TNA_DISMANTLE_END"
}

[ "$(id -u)" -eq 0 ] || die "run as root"

case "$MODE" in
  --capture-baseline) capture_baseline ;;
  --status) dismantle_status ;;
  --plan) plan "${TARGET:-full}" ;;
  --execute-proxy-only) execute_proxy_only ;;
  --execute) execute_dismantle full ;;
  --execute-full) execute_dismantle full ;;
  --execute-remaining-drive) execute_dismantle remaining-drive ;;
  *) die "usage: $0 {--capture-baseline|--status|--plan proxy-only|full|remaining-drive|--execute-proxy-only|--execute-full|--execute-remaining-drive}" ;;
esac
