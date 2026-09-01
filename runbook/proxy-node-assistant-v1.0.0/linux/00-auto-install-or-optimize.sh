#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/linux/lib-gui-prompt.sh"
PRIVATE_DIR="/root/.config/proxy-runbook"
PUBLIC_DIR="/etc/proxy-runbook"
RUN_STATUS_FILE="$PUBLIC_DIR/last-run.env"
mkdir -p "$PRIVATE_DIR" "$PUBLIC_DIR"
chmod 700 "$PRIVATE_DIR"
chmod 755 "$PUBLIC_DIR"

. "$ROOT/linux/lib-handoff.sh"

export DEBIAN_FRONTEND=noninteractive

green(){ printf '\033[32m%s\033[0m\n' "$*"; }
yellow(){ printf '\033[33m%s\033[0m\n' "$*"; }
red(){ printf '\033[31m%s\033[0m\n' "$*"; }

CURRENT_STAGE="INITIALIZATION"
RUN_COMPLETE=0
AUTO_INPUT="${TNA_AUTO_INPUT:-${PROXY_RUNBOOK_AUTO_INPUT:-}}"

cleanup_auto_input() {
  if [ -n "$AUTO_INPUT" ]; then
    rm -f -- "$AUTO_INPUT" 2>/dev/null || true
  fi
}

write_run_status() {
  local status="$1" rc="${2:-0}" tmp
  tmp="$(mktemp)"
  {
    printf 'RUN_STATUS=%s\n' "$status"
    printf 'RUN_STAGE=%s\n' "$CURRENT_STAGE"
    printf 'RUN_EXIT_CODE=%s\n' "$rc"
    printf 'RUN_UPDATED=%s\n' "$(date -Is)"
  } > "$tmp"
  install -m 644 "$tmp" "$RUN_STATUS_FILE"
  rm -f "$tmp"
}

on_run_exit() {
  local rc=$?
  cleanup_auto_input
  if [ "$rc" -ne 0 ] && [ "$RUN_COMPLETE" -ne 1 ]; then
    write_run_status FAILED "$rc" 2>/dev/null || true
    printf '\nPROXY_RUNBOOK_REMOTE_FAILURE stage=%s rc=%s\n' "$CURRENT_STAGE" "$rc" >&2
  fi
}
trap on_run_exit EXIT

step(){
  CURRENT_STAGE="$*"
  write_run_status RUNNING 0
  printf '\n\033[1m===== %s =====\033[0m\n' "$*"
}

AUTO_DEFAULTS="${PROXY_RUNBOOK_ASSUME_DEFAULTS:-0}"
RUN_LANG="${PROXY_RUNBOOK_LANG:-en}"
COVER_TEMPLATE_CHOICE="${TNA_COVER_TEMPLATE:-${PROXY_RUNBOOK_COVER_TEMPLATE:-auto}}"
PLAN_CONFIRMED="${TNA_PLAN_CONFIRMED:-0}"

# Reset-line install plan.  An omitted value follows the v0.9.0 compatible
# path; an explicitly supplied unknown value is always rejected before any
# package, service, firewall, panel, route, or certificate change.
if [ -n "${TNA_ROUTE_MODE+x}" ]; then
  ROUTE_MODE="$TNA_ROUTE_MODE"
else
  ROUTE_MODE="gray"
fi
PERFORMANCE_MODE_EXPLICIT=0
if [ -n "${TNA_PERFORMANCE_MODE+x}" ]; then
  PERFORMANCE_MODE="$TNA_PERFORMANCE_MODE"
  PERFORMANCE_MODE_EXPLICIT=1
else
  PERFORMANCE_MODE="legacy"
fi
WARP_MODE_EXPLICIT=0
if [ -n "${TNA_WARP_MODE+x}" ]; then
  WARP_MODE="$TNA_WARP_MODE"
  WARP_MODE_EXPLICIT=1
else
  WARP_MODE="legacy"
fi

REALITY_PRODUCTION_PORT="${TNA_REALITY_PRODUCTION_PORT:-${TNA_REALITY_PORT:-443}}"
REALITY_SHADOW_PORT="${TNA_REALITY_SHADOW_PORT:-24443}"
CDN_ORIGIN_PORT="${TNA_CDN_ORIGIN_PORT:-${TNA_CDN_EDGE_ORIGIN_PORT:-8443}}"
WARP_LOOPBACK_PORT="${TNA_WARP_LOOPBACK_PORT:-${TNA_WARP_PORT:-40000}}"
# v1.0.0 formal SS2022 listener.  The old 30443 trial remains accepted when
# explicitly supplied by an existing-node migration; it is not the new default.
SS2022_TCP_PORT="${PNA_SS2022_PORT:-32443}"

config_error() {
  red "INSTALL_PLAN_INVALID: $*"
  exit 64
}

case "$ROUTE_MODE" in keep|gray|orange|dual) ;; *) config_error "unknown TNA_ROUTE_MODE='$ROUTE_MODE'";; esac
if [ "$PERFORMANCE_MODE_EXPLICIT" -eq 1 ]; then
  case "$PERFORMANCE_MODE" in preserve|auto|low|standard|high) ;; *) config_error "unknown TNA_PERFORMANCE_MODE='$PERFORMANCE_MODE'";; esac
fi
if [ "$WARP_MODE_EXPLICIT" -eq 1 ]; then
  case "$WARP_MODE" in preserve|ensure-on) ;; *) config_error "unknown TNA_WARP_MODE='$WARP_MODE'";; esac
fi
case "$PLAN_CONFIRMED" in 0|1) ;; *) config_error "unknown TNA_PLAN_CONFIRMED='$PLAN_CONFIRMED'";; esac
[ "$REALITY_PRODUCTION_PORT" = 443 ] || config_error "TNA_REALITY_PRODUCTION_PORT must be 443"
[ "$REALITY_SHADOW_PORT" = 24443 ] || config_error "TNA_REALITY_SHADOW_PORT must be 24443"
[ "$CDN_ORIGIN_PORT" = 8443 ] || config_error "TNA_CDN_ORIGIN_PORT must be 8443"
[ "$WARP_LOOPBACK_PORT" = 40000 ] || config_error "TNA_WARP_LOOPBACK_PORT must be 40000"
[[ "$SS2022_TCP_PORT" =~ ^[0-9]+$ ]] || config_error "PNA_SS2022_PORT must be numeric"
[ "$SS2022_TCP_PORT" -ge 1024 ] && [ "$SS2022_TCP_PORT" -le 65535 ] || config_error "PNA_SS2022_PORT must be between 1024 and 65535"
case "$SS2022_TCP_PORT" in
  "$REALITY_PRODUCTION_PORT"|"$REALITY_SHADOW_PORT"|"$CDN_ORIGIN_PORT"|"$WARP_LOOPBACK_PORT")
    config_error "PNA_SS2022_PORT conflicts with a coordinated listener"
    ;;
esac

case "$RUN_LANG" in zh|en) ;; *) RUN_LANG=en;; esac
GRAY_ROUTE=0
ORANGE_ROUTE=0
case "$ROUTE_MODE" in
  gray) GRAY_ROUTE=1 ;;
  orange) ORANGE_ROUTE=1 ;;
  dual) GRAY_ROUTE=1; ORANGE_ROUTE=1 ;;
esac

yesq() {
  local prompt="$1" ans
  if [ "$AUTO_DEFAULTS" = "1" ]; then
    echo "$prompt [AUTO=Y]"
    return 0
  fi
  ans="$(proxy_runbook_read_answer "$prompt [Y/n]")" || return 1
  case "${ans:-y}" in y|Y|yes|YES) return 0;; *) return 1;; esac
}
noq() {
  local prompt="$1" ans
  if [ "$AUTO_DEFAULTS" = "1" ]; then
    echo "$prompt [AUTO=N]"
    return 1
  fi
  ans="$(proxy_runbook_read_answer "$prompt [y/N]")" || return 1
  case "${ans:-n}" in y|Y|yes|YES) return 0;; *) return 1;; esac
}
human_yesq() {
  local zh="$1" en="$2" ans prompt
  if [ "$RUN_LANG" = "zh" ]; then prompt="$zh"; else prompt="$en"; fi
  ans="$(proxy_runbook_read_answer "$prompt [Y/n]")" || return 1
  case "${ans:-y}" in y|Y|yes|YES) return 0;; *) return 1;; esac
}
required() {
  local prompt="$1" v=""
  while [ -z "$v" ]; do
    v="$(proxy_runbook_read_answer "$prompt")" || return 1
    v="$(printf '%s' "$v" | xargs)"
    [ -n "$v" ] || yellow "Required. There is intentionally no default." >&2
  done
  printf '%s' "$v"
}

valid_domain() {
  [[ "$1" =~ ^([A-Za-z0-9][A-Za-z0-9-]*\.)+[A-Za-z]{2,63}$ ]]
}

valid_email() {
  [[ "$1" =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]]
}

mask_email() {
  local value="$1" local_part domain_part
  local_part="${value%%@*}"
  domain_part="${value#*@}"
  if [ -z "$local_part" ] || [ "$domain_part" = "$value" ]; then
    printf '%s' '***'
  else
    printf '%s***@%s' "${local_part:0:1}" "$domain_part"
  fi
}

read_domain() {
  local value="$1" prompt="$2"
  while ! valid_domain "$value"; do
    [ -z "$value" ] || yellow "Invalid hostname; use a full hostname such as cover.example.com." >&2
    value="$(required "$prompt")"
  done
  printf '%s' "$value"
}

read_email() {
  local value="$1" prompt="$2"
  while ! valid_email "$value"; do
    [ -z "$value" ] || yellow "Invalid email address." >&2
    value="$(required "$prompt")"
  done
  printf '%s' "$value"
}

# Optional privacy-preserving auto-input file written by the client.  The
# randomized path is supplied by TNA_AUTO_INPUT; no fixed /tmp filename is
# assumed.  Legacy DOMAIN_B64/EMAIL_B64 keys remain read-only compatibility
# inputs for an older client invoking the gray route.
INPUT_GRAY_DOMAIN=""
INPUT_GRAY_EMAIL=""
INPUT_ORANGE_DOMAIN=""
INPUT_ORANGE_EMAIL=""
if [ -n "$AUTO_INPUT" ] && [ ! -r "$AUTO_INPUT" ]; then
  config_error "TNA_AUTO_INPUT is not readable"
fi
if [ -n "$AUTO_INPUT" ]; then
  GDB64="$(sed -n 's/^GRAY_DOMAIN_B64=//p' "$AUTO_INPUT" | sed -n '1p')"
  GEB64="$(sed -n 's/^GRAY_EMAIL_B64=//p' "$AUTO_INPUT" | sed -n '1p')"
  ODB64="$(sed -n 's/^ORANGE_DOMAIN_B64=//p' "$AUTO_INPUT" | sed -n '1p')"
  OEB64="$(sed -n 's/^ORANGE_EMAIL_B64=//p' "$AUTO_INPUT" | sed -n '1p')"
  [ -n "$GDB64" ] || GDB64="$(sed -n 's/^DOMAIN_B64=//p' "$AUTO_INPUT" | sed -n '1p')"
  [ -n "$GEB64" ] || GEB64="$(sed -n 's/^EMAIL_B64=//p' "$AUTO_INPUT" | sed -n '1p')"
  LB="$(sed -n 's/^LANG=//p' "$AUTO_INPUT" | sed -n '1p')"
  [ -n "$GDB64" ] && INPUT_GRAY_DOMAIN="$(printf '%s' "$GDB64" | base64 -d 2>/dev/null || true)"
  [ -n "$GEB64" ] && INPUT_GRAY_EMAIL="$(printf '%s' "$GEB64" | base64 -d 2>/dev/null || true)"
  [ -n "$ODB64" ] && INPUT_ORANGE_DOMAIN="$(printf '%s' "$ODB64" | base64 -d 2>/dev/null || true)"
  [ -n "$OEB64" ] && INPUT_ORANGE_EMAIL="$(printf '%s' "$OEB64" | base64 -d 2>/dev/null || true)"
  case "$LB" in zh|en) RUN_LANG="$LB";; esac
  # The decoded values now live only in this process. Remove the randomized
  # one-run file immediately; the EXIT trap remains as the failure fallback.
  cleanup_auto_input
fi

[ "$(id -u)" -eq 0 ] || { red "Run as root/sudo."; exit 1; }
. /etc/os-release
case "${ID:-}" in
  ubuntu|debian) ;;
  *) red "Adaptive AUTO currently supports Ubuntu/Debian only. Detected: ${ID:-unknown}"; exit 1 ;;
esac

PUBLIC_IP="$(curl -4fsS --max-time 10 https://api.ipify.org 2>/dev/null || true)"
[ -n "$PUBLIC_IP" ] || PUBLIC_IP="$(hostname -I | awk '{print $1}')"
SSH_PORT="$(sshd -T 2>/dev/null | awk '$1=="port" && !found {print $2; found=1}')"
SSH_PORT="${SSH_PORT:-22}"
LOGIN_USER="${PROXY_RUNBOOK_LOGIN_USER:-${SUDO_USER:-root}}"
SSH_SOURCE="${SSH_CONNECTION%% *}"

EXISTING=0
NODE_MODE="FRESH"
if [ -x /usr/local/x-ui/x-ui ] || systemctl list-unit-files 2>/dev/null | grep '^x-ui\.service' >/dev/null; then
  EXISTING=1
  NODE_MODE="EXISTING"
fi

if [ "$ROUTE_MODE" = keep ] && [ "$EXISTING" -ne 1 ]; then
  config_error "TNA_ROUTE_MODE=keep is available only when an existing 3x-ui node was detected"
fi

# v0.9.0 revision 5+: capture the pre-convergence state once, before package,
# service, firewall, panel, cover, WARP, or performance changes. Older nodes
# with existing runbook markers are labelled LEGACY_UNCERTAIN.
bash "$ROOT/linux/22-dismantle-managed-node.sh" --capture-baseline

step "AUTO DETECTION"
echo "Public IP     : $PUBLIC_IP"
echo "SSH user      : $LOGIN_USER"
echo "SSH port      : $SSH_PORT"
echo "SSH source IP : ${SSH_SOURCE:-unknown}"
if [ "$EXISTING" -eq 1 ]; then
  green "MODE=EXISTING → backup + audit + safe convergence"
else
  green "MODE=FRESH → unattended install"
  PRE80="$(ss -lntp 2>/dev/null | grep -E ':80[[:space:]]' || true)"
  PRE443="$(ss -lntp 2>/dev/null | grep -E ":${REALITY_PRODUCTION_PORT}[[:space:]]" || true)"
  if [ -n "$PRE80" ] || [ -n "$PRE443" ]; then
    yellow "This machine has no 3x-ui, but port 80 and/or 443 is already occupied:"
    [ -n "$PRE80" ] && printf '%s\n' "$PRE80"
    [ -n "$PRE443" ] && printf '%s\n' "$PRE443"
    echo
    echo "This is not a clean blank VPS. Automatic installation will not assume those services are disposable."
    if ! noq "Continue anyway after you have verified those listeners are safe to coexist/replace?"; then
      red "Stopped before modifying the machine."
      exit 4
    fi
  fi
fi

# A new run gets a new truth handoff. Older handoffs are archived root-only,
# never silently presented as freshly verified credentials.
handoff_begin_run
handoff_set "NODE_MODE" "$NODE_MODE"
handoff_set "VPS_LOGIN_USER" "$LOGIN_USER"

echo
echo "Shared package privacy rule:"
echo "  - no real node IP/domain/account is baked into the toolkit"
echo "  - current initial SSH password is handled only by OpenSSH, not this script"
echo "  - generated credentials are shown in full during HANDOFF"
echo

# Route identities exist only for this run. The client previews and confirms
# the complete plan before upload; standalone/legacy use still receives one
# final confirmation here. Email local-parts are never printed in full.
step "EXPLICIT INSTALL PLAN INPUTS"
GRAY_DOMAIN=""
GRAY_EMAIL=""
ORANGE_DOMAIN=""
ORANGE_EMAIL=""
DOMAIN=""
ACME_EMAIL=""

if [ "$GRAY_ROUTE" -eq 1 ]; then
  if [ "$RUN_LANG" = zh ]; then
    GRAY_DOMAIN="$(read_domain "$INPUT_GRAY_DOMAIN" "请输入灰云/DNS-only 域名，例如 cover.example.com")"
    GRAY_EMAIL="$(read_email "$INPUT_GRAY_EMAIL" "请输入灰云证书所需邮箱")"
  else
    GRAY_DOMAIN="$(read_domain "$INPUT_GRAY_DOMAIN" "Type the gray/DNS-only hostname, for example cover.example.com")"
    GRAY_EMAIL="$(read_email "$INPUT_GRAY_EMAIL" "Type the ACME email for the gray route")"
  fi
  DOMAIN="$GRAY_DOMAIN"
  ACME_EMAIL="$GRAY_EMAIL"
fi

if [ "$ORANGE_ROUTE" -eq 1 ]; then
  if [ "$RUN_LANG" = zh ]; then
    ORANGE_DOMAIN="$(read_domain "$INPUT_ORANGE_DOMAIN" "请输入橙云/Proxied 域名，例如 www.example.com")"
    ORANGE_EMAIL="$(read_email "$INPUT_ORANGE_EMAIL" "请输入橙云源站证书所需邮箱")"
  else
    ORANGE_DOMAIN="$(read_domain "$INPUT_ORANGE_DOMAIN" "Type the orange/Proxied hostname, for example www.example.com")"
    ORANGE_EMAIL="$(read_email "$INPUT_ORANGE_EMAIL" "Type the origin-certificate email for the orange route")"
  fi
fi

if [ "$ROUTE_MODE" = dual ] && [ "${GRAY_DOMAIN,,}" = "${ORANGE_DOMAIN,,}" ]; then
  config_error "dual mode requires two different hostnames"
fi

echo "INSTALL_PLAN_ROUTE=$ROUTE_MODE"
echo "INSTALL_PLAN_PERFORMANCE=$PERFORMANCE_MODE"
echo "INSTALL_PLAN_WARP=$WARP_MODE"
echo "INSTALL_PLAN_PORTS=${REALITY_PRODUCTION_PORT}/${REALITY_SHADOW_PORT}/${CDN_ORIGIN_PORT}/${WARP_LOOPBACK_PORT}/${SS2022_TCP_PORT}"
if [ "$GRAY_ROUTE" -eq 1 ]; then
  echo "GRAY_DOMAIN=$GRAY_DOMAIN"
  echo "GRAY_EMAIL=$(mask_email "$GRAY_EMAIL")"
fi
if [ "$ORANGE_ROUTE" -eq 1 ]; then
  echo "ORANGE_DOMAIN=$ORANGE_DOMAIN"
  echo "ORANGE_EMAIL=$(mask_email "$ORANGE_EMAIL")"
  yellow "Orange/CDN convergence is intentionally handed to the post-core CDN module."
fi
if [ "$ROUTE_MODE" = keep ]; then
  green "KEEP_ROUTE_SELECTED: certificate, cover route, subscription route, and Reality topology will not be changed."
fi
if [ "$PLAN_CONFIRMED" = 1 ]; then
  green "INSTALL_PLAN_ALREADY_CONFIRMED_BY_CLIENT"
else
  yesq "Continue using this exact install plan?" || exit 0
fi

if [ "$EXISTING" -eq 1 ]; then
  step "BACKUP BEFORE EXISTING-NODE CHANGES"
  bash "$ROOT/linux/01-safe-backup.sh"
fi

step "BASE PACKAGES"
MISSING_BASE=()
BASE_COMMANDS=(curl wget jq openssl ufw tcpdump fail2ban-client zip unzip sudo)
BASE_PACKAGES=(curl wget ca-certificates gnupg lsb-release jq openssl ufw tcpdump fail2ban zip unzip sudo)
if [ "$ROUTE_MODE" != keep ]; then
  BASE_COMMANDS+=(nginx certbot)
  BASE_PACKAGES+=(nginx certbot python3-certbot-nginx)
fi
for cmd in "${BASE_COMMANDS[@]}"; do
  command -v "$cmd" >/dev/null 2>&1 || MISSING_BASE+=("$cmd")
done
if [ "${#MISSING_BASE[@]}" -gt 0 ]; then
  yellow "Missing base commands: ${MISSING_BASE[*]}"
  apt-get update
  apt-get install -y "${BASE_PACKAGES[@]}"
else
  green "BASE_PACKAGES_ALREADY_PRESENT — skipped apt update/install"
fi
systemctl enable --now fail2ban
if [ "$ROUTE_MODE" != keep ]; then
  systemctl enable --now nginx
fi
green "BASE_OK"

step "ADAPTIVE PERFORMANCE PROFILE"
case "$PERFORMANCE_MODE" in
  preserve)
    green "PERFORMANCE_PRESERVED_NO_CHANGES"
    ;;
  auto|low|standard|high)
    bash "$ROOT/linux/20-adaptive-performance.sh" --detect
    bash "$ROOT/linux/20-adaptive-performance.sh" --apply "$PERFORMANCE_MODE"
    ;;
  legacy)
    bash "$ROOT/linux/20-adaptive-performance.sh" --detect
    if yesq "Apply the rollback-capable hardware-adaptive performance profile now?"; then
      bash "$ROOT/linux/20-adaptive-performance.sh" --apply auto
    else
      yellow "Adaptive performance changes were skipped. Menu [16] can apply them later."
    fi
    ;;
esac

step "FIREWALL BASELINE"
ufw allow "${SSH_PORT}/tcp"
if [ "$GRAY_ROUTE" -eq 1 ]; then
  ufw allow 80/tcp
  ufw allow "${REALITY_PRODUCTION_PORT}/tcp"
fi
ufw --force enable

remove_public_rule_for_port() {
  local p="$1" nums=()
  [ -n "$p" ] || return 0
  mapfile -t nums < <(ufw status numbered | grep -E "${p}(/tcp)?[[:space:]].*ALLOW[[:space:]].*Anywhere" \
    | sed -n 's/^\[[[:space:]]*\([0-9]\+\)\].*/\1/p' | sort -rn)
  if [ "${#nums[@]}" -gt 0 ]; then
    yellow "Public UFW ALLOW rule(s) found for localhost-only service port $p."
    if yesq "Remove those public $p allow rule(s)?"; then
      local n
      for n in "${nums[@]}"; do yes | ufw delete "$n" >/dev/null; done
      green "Removed public $p UFW allow rule(s)."
    fi
  fi
}
if [ "$GRAY_ROUTE" -eq 1 ]; then
  remove_public_rule_for_port "$CDN_ORIGIN_PORT"
fi
if [ "$WARP_MODE" != preserve ]; then
  remove_public_rule_for_port "$WARP_LOOPBACK_PORT"
fi

step "3X-UI"
XUI="/usr/local/x-ui/x-ui"
if [ "$EXISTING" -eq 0 ]; then
  if yesq "Install official stable 3x-ui unattended with UNIQUE RANDOM credentials?"; then
    export XUI_NONINTERACTIVE=1
    export XUI_SSL_MODE=none
    export XUI_DB_TYPE=sqlite
    # Intentionally do NOT set username/password/panel port/web path:
    # official installer generates unique random values.
    bash <(curl -Ls https://raw.githubusercontent.com/MHSanaei/3x-ui/master/install.sh)
    EXISTING=1
  else
    red "Fresh node cannot continue without 3x-ui."; exit 1
  fi
fi

[ -x "$XUI" ] || { red "3x-ui binary missing."; exit 1; }

SHOW="$("$XUI" setting -show 2>/dev/null || true)"
PANEL_PORT="$(printf '%s\n' "$SHOW" | sed -nE 's/^[[:space:]]*(port|panelPort):[[:space:]]*([0-9]+).*$/\2/p' | sed -n '1p')"
[ -n "$PANEL_PORT" ] || PANEL_PORT="$(sed -n 's/^XUI_PANEL_PORT=//p' /etc/x-ui/install-result.env 2>/dev/null | sed -n '1p')"
[ -n "$PANEL_PORT" ] || { red "Cannot discover 3x-ui panel port."; exit 1; }
PANEL_LISTEN="$("$XUI" setting -getListen 2>/dev/null | sed -n 's/^listenIP:[[:space:]]*//p' | sed -n '1p')"
PANEL_LISTEN="${PANEL_LISTEN:-0.0.0.0}"

if [ "$PANEL_LISTEN" != "127.0.0.1" ]; then
  yellow "Panel listen drift: $PANEL_LISTEN -> target localhost only."
  if yesq "Bind the existing panel to 127.0.0.1 while preserving its current random port?"; then
    "$XUI" setting -listenIP 127.0.0.1
    systemctl restart x-ui
    sleep 2
  fi
fi

remove_public_rule_for_port "$PANEL_PORT"

SHOW="$("$XUI" setting -show 2>/dev/null || true)"
RAW_PATH="$(printf '%s\n' "$SHOW" | sed -nE 's/^[[:space:]]*(webBasePath|web base path):[[:space:]]*(.*)$/\2/p' | sed -n '1p')"
CLEAN_PATH="${RAW_PATH#/}"; CLEAN_PATH="${CLEAN_PATH%/}"
if [ -z "$CLEAN_PATH" ] || [ "${#CLEAN_PATH}" -lt 10 ]; then
  yellow "Panel WebBasePath is empty/short."
  if yesq "Generate a new random WebBasePath now?"; then
    NEW_PATH="$(openssl rand -hex 12)"
    "$XUI" setting -webBasePath "$NEW_PATH"
    systemctl restart x-ui
    sleep 2
    RAW_PATH="/${NEW_PATH}/"
    CLEAN_PATH="$NEW_PATH"
    green "WEB_BASE_PATH_RANDOMIZED"
  fi
fi

# Fresh official credentials are shown in full; existing panel creds are exported where retrievable.
bash "$ROOT/linux/03d-export-panel-handoff.sh" "$NODE_MODE"

if [ "$NODE_MODE" = "EXISTING" ] && ! grep -q '^PANEL_PASSWORD=' "$HANDOFF_FILE" 2>/dev/null; then
  if noq "Existing panel password is not safely recoverable. Rotate panel username/password to new random values and show them now? (3x-ui will log out existing sessions; credential reset may disable existing 2FA)"; then
    bash "$ROOT/linux/03c-rotate-panel-credentials.sh"
    SHOW="$("$XUI" setting -show 2>/dev/null || true)"
    PANEL_PORT="$(printf '%s\n' "$SHOW" | sed -nE 's/^[[:space:]]*(port|panelPort):[[:space:]]*([0-9]+).*$/\2/p' | sed -n '1p')"
    RAW_PATH="$(printf '%s\n' "$SHOW" | sed -nE 's/^[[:space:]]*(webBasePath|web base path):[[:space:]]*(.*)$/\2/p' | sed -n '1p')"
  fi
fi

write_public_metadata() {
  local tmp metadata_cover metadata_reality
  metadata_cover="$(sed -n 's/^COVER_DOMAIN=//p' "$PUBLIC_DIR/public.env" 2>/dev/null | sed -n '1p')"
  metadata_reality="$(sed -n 's/^REALITY_TARGET=//p' "$PUBLIC_DIR/public.env" 2>/dev/null | sed -n '1p')"
  if [ "$GRAY_ROUTE" -eq 1 ]; then
    metadata_cover="$GRAY_DOMAIN"
    metadata_reality="127.0.0.1:${CDN_ORIGIN_PORT}"
  fi
  tmp="$(mktemp)"
  if [ -f "$PUBLIC_DIR/public.env" ]; then
    grep -Ev '^(PUBLIC_IP|SSH_PORT|PANEL_PORT|WEB_BASE_PATH|COVER_DOMAIN|REALITY_TARGET|INSTALL_PLAN_ROUTE_MODE|REALITY_PRODUCTION_PORT|REALITY_SHADOW_PORT|CDN_ORIGIN_PORT|WARP_PROXY_PORT)=' \
      "$PUBLIC_DIR/public.env" > "$tmp" || true
  fi
  cat >> "$tmp" <<EOF
PUBLIC_IP=$PUBLIC_IP
SSH_PORT=$SSH_PORT
PANEL_PORT=$PANEL_PORT
WEB_BASE_PATH=$RAW_PATH
COVER_DOMAIN=$metadata_cover
REALITY_TARGET=$metadata_reality
INSTALL_PLAN_ROUTE_MODE=$ROUTE_MODE
REALITY_PRODUCTION_PORT=$REALITY_PRODUCTION_PORT
REALITY_SHADOW_PORT=$REALITY_SHADOW_PORT
CDN_ORIGIN_PORT=$CDN_ORIGIN_PORT
WARP_PROXY_PORT=$WARP_LOOPBACK_PORT
EOF
  install -m 644 "$tmp" "$PUBLIC_DIR/public.env"
  rm -f "$tmp"
}

# Publish non-secret panel metadata as soon as it is known.  v0.6 wrote this
# only after cover/certificate/WARP work, so an unrelated later failure made
# the Windows client believe the panel port was empty.
write_public_metadata

step "SSH / VPS LOGIN CREDENTIALS"
# Windows launcher installs and verifies SSH key BEFORE this wizard.
# Fresh node: rotate provider-supplied password by default.
# Existing node: do not surprise-rotate on every maintenance run.
if [ ! -f "$PRIVATE_DIR/vps-password-generated.marker" ]; then
  if [ "$NODE_MODE" = "EXISTING" ]; then
    if noq "Rotate VPS login password for '$LOGIN_USER' to a new random value and show it in full?"; then
      bash "$ROOT/linux/01a-rotate-vps-password.sh" "$LOGIN_USER"
      touch "$PRIVATE_DIR/vps-password-generated.marker"; chmod 600 "$PRIVATE_DIR/vps-password-generated.marker"
    fi
  else
    if yesq "Replace the provider-supplied VPS password for '$LOGIN_USER' with a new random value now?"; then
      bash "$ROOT/linux/01a-rotate-vps-password.sh" "$LOGIN_USER"
      touch "$PRIVATE_DIR/vps-password-generated.marker"; chmod 600 "$PRIVATE_DIR/vps-password-generated.marker"
    fi
  fi
else
  green "A runbook-generated VPS password already has a local marker; not rotating it again automatically."
fi

echo
echo "Server SSH host public-key fingerprint:"
if [ -f /etc/ssh/ssh_host_ed25519_key.pub ]; then
  ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub || true
fi
echo "Server host PRIVATE keys remain on this VPS and are intentionally never exported."

if [ "$GRAY_ROUTE" -eq 1 ]; then
step "DNS FOR THE HUMAN-TYPED GRAY DOMAIN"
dns_points_here() {
  getent ahostsv4 "$DOMAIN" 2>/dev/null | awk '{print $1}' | grep -x "$PUBLIC_IP" >/dev/null
}
if ! dns_points_here; then
  yellow "$DOMAIN does not currently resolve to $PUBLIC_IP."
  echo
  echo "Manual DNS record:"
  echo "  Type    : A"
  echo "  Name    : $DOMAIN"
  echo "  Content : $PUBLIC_IP"
  echo "  Proxy   : DNS only"
  echo
  if noq "If this zone is on Cloudflare, use a temporary DNS-Write API Token to update it automatically?"; then
    bash "$ROOT/linux/05a-cloudflare-dns-upsert.sh" "$DOMAIN" "$PUBLIC_IP"
  else
    until dns_points_here; do
      yesq "Have you manually created/updated the A record? Re-check DNS now?" || {
        yellow "Paused before certificate/REALITY. Nothing will guess your domain."
        exit 2
      }
      sleep 3
    done
  fi
  for _ in $(seq 1 40); do dns_points_here && break; sleep 3; done
fi
dns_points_here || { red "DNS still does not point to this VPS."; exit 2; }
green "DNS_OK"

step "NGINX + LET'S ENCRYPT + LOCALHOST:${CDN_ORIGIN_PORT}"
TLS_OK=0
if [ -f "/etc/letsencrypt/live/${DOMAIN}/fullchain.pem" ] && \
   ss -lntp 2>/dev/null | grep "127.0.0.1:${CDN_ORIGIN_PORT}" >/dev/null && \
   nginx -t >/dev/null 2>&1; then
  if curl -fsS --max-time 10 --resolve "${DOMAIN}:${CDN_ORIGIN_PORT}:127.0.0.1" \
       "https://${DOMAIN}:${CDN_ORIGIN_PORT}/" >/dev/null 2>&1; then
    TLS_OK=1
  fi
fi
if [ "$TLS_OK" -eq 1 ]; then
  green "COVER_TLS_ALREADY_MATCHES_HUMAN_INPUT"
else
  bash "$ROOT/linux/05-cover-bootstrap.sh" "$DOMAIN" "$ACME_EMAIL"
fi

step "POLISHED COVER FRONTEND / BACKEND"
COVER_KIND="missing"
if [ -f /var/www/cover/.proxy-runbook-cover ]; then
  COVER_KIND="managed"
elif [ -f /var/www/cover/index.html ] && grep -qE 'This site is online|<h1>Welcome</h1>' /var/www/cover/index.html; then
  COVER_KIND="placeholder"
elif [ -f /var/www/cover/index.html ]; then
  COVER_KIND="custom"
fi

case "$COVER_KIND" in
  managed)
    if yesq "Refresh/optimize the managed polished cover site and Nginx fallback?"; then
      bash "$ROOT/linux/05b-cover-site-polished.sh" "$DOMAIN" auto "$COVER_TEMPLATE_CHOICE"
    fi
    ;;
  placeholder)
    if yesq "Replace the minimal placeholder page with a polished static cover site?"; then
      bash "$ROOT/linux/05b-cover-site-polished.sh" "$DOMAIN" auto "$COVER_TEMPLATE_CHOICE"
    fi
    ;;
  custom)
    yellow "A custom/non-runbook cover site exists. It will be preserved by default."
    if noq "Back it up and replace it with the runbook polished cover site?"; then
      REPLACE_COVER=1 bash "$ROOT/linux/05b-cover-site-polished.sh" "$DOMAIN" auto "$COVER_TEMPLATE_CHOICE"
    fi
    ;;
  missing)
    if yesq "Create a polished public cover site now?"; then
      bash "$ROOT/linux/05b-cover-site-polished.sh" "$DOMAIN" auto "$COVER_TEMPLATE_CHOICE"
    fi
    ;;
esac

# A runbook-managed cover vhost is safe to converge independently of whether
# the operator refreshed the static artwork.  This also exposes only /sub/
# through the existing cover TLS path while the 3x-ui subscription listener
# remains bound to localhost.
if [ -f /var/www/cover/.proxy-runbook-cover ]; then
  bash "$ROOT/linux/05c-optimize-cover-backend.sh" "$DOMAIN"
  bash "$ROOT/linux/05d-configure-subscription.sh" "$DOMAIN" 2096
else
  yellow "Custom cover site preserved; automatic HTTPS subscription proxy was not installed."
fi
else
  green "GRAY_ROUTE_SKIPPED mode=$ROUTE_MODE"
fi

step "WARP / MASQUE LOCAL PROXY"
WARP_OK=0
WARP_ROUTE_RECONCILE=0
if [ "$WARP_MODE" = preserve ]; then
  green "WARP_PRESERVED_NO_INSTALL_NO_ROUTE_CHANGE"
else
  if command -v warp-cli >/dev/null 2>&1 && systemctl is-active --quiet warp-svc 2>/dev/null; then
    TRACE="$(curl -fsS --max-time 20 --proxy "socks5h://127.0.0.1:${WARP_LOOPBACK_PORT}" \
      https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null || true)"
    if grep -q '^warp=on$' <<<"$TRACE" && ss -lntp 2>/dev/null | grep "127.0.0.1:${WARP_LOOPBACK_PORT}" >/dev/null; then
      WARP_OK=1
    fi
  fi
  if [ "$WARP_OK" -eq 1 ]; then
    green "WARP_PROXY_ALREADY_OPTIMAL"
    WARP_ROUTE_RECONCILE=1
  elif [ "$WARP_MODE" = ensure-on ]; then
    command -v warp-cli >/dev/null 2>&1 || bash "$ROOT/linux/06-warp-install.sh"
    bash "$ROOT/linux/07-warp-configure-proxy.sh" "$WARP_LOOPBACK_PORT"
    WARP_OK=1
    WARP_ROUTE_RECONCILE=1
  elif yesq "Install/normalize WARP Local Proxy using MASQUE on localhost:${WARP_LOOPBACK_PORT}?"; then
    command -v warp-cli >/dev/null 2>&1 || bash "$ROOT/linux/06-warp-install.sh"
    bash "$ROOT/linux/07-warp-configure-proxy.sh" "$WARP_LOOPBACK_PORT"
    WARP_OK=1
    WARP_ROUTE_RECONCILE=1
  fi
fi

# Refresh runtime public metadata after convergence.  It was already written
# once immediately after panel discovery so failure branches can still open or
# diagnose the localhost-only panel deliberately.
SHOW="$("$XUI" setting -show 2>/dev/null || true)"
PANEL_PORT_NEW="$(printf '%s\n' "$SHOW" | sed -nE 's/^[[:space:]]*(port|panelPort):[[:space:]]*([0-9]+).*$/\2/p' | sed -n '1p')"
RAW_PATH_NEW="$(printf '%s\n' "$SHOW" | sed -nE 's/^[[:space:]]*(webBasePath|web base path):[[:space:]]*(.*)$/\2/p' | sed -n '1p')"
[ -n "$PANEL_PORT_NEW" ] && PANEL_PORT="$PANEL_PORT_NEW"
[ -n "$RAW_PATH_NEW" ] && RAW_PATH="$RAW_PATH_NEW"
write_public_metadata

if [ "$GRAY_ROUTE" -eq 1 ]; then
step "REALITY ${REALITY_PRODUCTION_PORT}"
set +e
RINSPECT="$(bash "$ROOT/linux/04a-reality-api.sh" inspect-443 "$DOMAIN" "$PUBLIC_IP" 2>&1)"
RC=$?
set -e
printf '%s\n' "$RINSPECT"

if [ "$RC" -eq 0 ]; then
  green "REALITY_443_ALREADY_OPTIMAL"
elif [ "$RC" -eq 4 ]; then
  bash "$ROOT/linux/04a-reality-api.sh" normalize-share "$PUBLIC_IP"
  green "REALITY_443_SUBSCRIPTION_SHARE_ADDRESS_FIXED"
elif [ "$RC" -eq 2 ]; then
  if yesq "No VLESS+REALITY ${REALITY_PRODUCTION_PORT} exists. Create a safe ${REALITY_SHADOW_PORT} shadow first?"; then
    if EXISTING_SHADOW="$(bash "$ROOT/linux/04a-reality-api.sh" show-shadow "$REALITY_SHADOW_PORT" 2>/dev/null)"; then
      printf '%s\n' "$EXISTING_SHADOW"
      green "EXISTING_${REALITY_SHADOW_PORT}_SHADOW_REUSED"
    else
      bash "$ROOT/linux/04a-reality-api.sh" create-test "$DOMAIN" "$PUBLIC_IP" "$REALITY_SHADOW_PORT"
    fi
    if [ -n "${SSH_SOURCE:-}" ]; then
      ufw allow from "$SSH_SOURCE" to any port "$REALITY_SHADOW_PORT" proto tcp comment 'proxy-runbook-reality-shadow'
    else
      yellow "Could not infer SSH source IP; ${REALITY_SHADOW_PORT} was not opened automatically."
    fi
    echo
    yellow "Import the printed ${REALITY_SHADOW_PORT} vless:// link into your client and REALLY browse through it."
    if human_yesq "你已经亲自把 ${REALITY_SHADOW_PORT} 链接导入客户端，并确认能正常上网了吗？" "Have you personally imported the ${REALITY_SHADOW_PORT} link and verified real browsing works?"; then
      bash "$ROOT/linux/04a-reality-api.sh" promote-shadow "$REALITY_SHADOW_PORT" "$REALITY_PRODUCTION_PORT"
      mapfile -t N < <(ufw status numbered | grep "$REALITY_SHADOW_PORT" | grep 'proxy-runbook-reality-shadow' \
        | sed -n 's/^\[[[:space:]]*\([0-9]\+\)\].*/\1/p' | sort -rn)
      for n in "${N[@]:-}"; do [ -n "$n" ] && yes | ufw delete "$n" >/dev/null || true; done
      green "PRODUCTION_443_CREATED"
    else
      yellow "Production 443 was not created. Shadow remains for debugging."
      exit 3
    fi
  fi
else
  yellow "Existing ${REALITY_PRODUCTION_PORT} differs from the local self-steal profile for the domain YOU typed."
  yellow "Direct rewrite is forbidden. Only a ${REALITY_SHADOW_PORT} clone/test/commit path is allowed."
  if yesq "Create an optimized ${REALITY_SHADOW_PORT} clone of existing ${REALITY_PRODUCTION_PORT} for A/B testing?"; then
    bash "$ROOT/linux/04d-optimize-existing-reality-shadow.sh" prepare "$DOMAIN" "$PUBLIC_IP" "$REALITY_SHADOW_PORT"
    echo
    yellow "Import a TEST link above. Save the FUTURE ${REALITY_PRODUCTION_PORT} link(s) too."
    if human_yesq "你已经亲自确认 ${REALITY_SHADOW_PORT} 正常，并保存了未来 ${REALITY_PRODUCTION_PORT} 链接吗？" "Have you personally verified ${REALITY_SHADOW_PORT} and saved the future ${REALITY_PRODUCTION_PORT} link(s)?"; then
      bash "$ROOT/linux/04d-optimize-existing-reality-shadow.sh" commit "$DOMAIN" "$PUBLIC_IP" "$REALITY_SHADOW_PORT"
      green "EXISTING_REALITY_CONVERGED"
    else
      if noq "Delete the temporary shadow now?"; then
        bash "$ROOT/linux/04d-optimize-existing-reality-shadow.sh" abort "$DOMAIN" "$PUBLIC_IP" "$REALITY_SHADOW_PORT"
      else
        yellow "Shadow left for later; production 443 unchanged."
      fi
    fi
  fi
fi
else
  green "REALITY_ROUTE_SKIPPED mode=$ROUTE_MODE"
fi

if [ "$WARP_OK" -eq 1 ] && [ "$WARP_ROUTE_RECONCILE" -eq 1 ]; then
  step "PERSISTENT OPENAI -> WARP ROUTING"
  . "$ROOT/linux/lib-xui-api.sh"
  if xui_api_context; then
    XR="$(xui_auth_curl -X POST "${XUI_BASE}/panel/api/xray/" || true)"
    HAVE="$(jq -r '
      try (.obj|fromjson|.xraySetting) catch {} |
      ((.outbounds // []) | any(.tag=="warp-masque")) and
      ((.routing.rules // []) | any(.ruleTag=="openai-via-warp"))
    ' <<<"$XR" 2>/dev/null || echo false)"
    if [ "$HAVE" = "true" ]; then
      green "XRAY_WARP_ROUTE_ALREADY_PERSISTENT"
    elif [ "$WARP_MODE" = ensure-on ]; then
      bash "$ROOT/linux/07a-apply-warp-route-local.sh" "$WARP_LOOPBACK_PORT"
    elif yesq "Add persistent OpenAI/ChatGPT -> WARP route while preserving unrelated Xray config?"; then
      bash "$ROOT/linux/07a-apply-warp-route-local.sh" "$WARP_LOOPBACK_PORT"
    fi
  fi
fi

step "SHADOWSOCKS 2022 TCP-ONLY"
echo "SS2022_PORT=$SS2022_TCP_PORT"
echo "SS2022_ALLOWLIST_POLICY=EXACT_IPV4_SOURCE_ONLY"
bash "$ROOT/linux/23-ss2022-tcp.sh" ensure "$SS2022_TCP_PORT"
SS2022_ALLOWED_COUNT="$(grep -c . /etc/proxy-runbook/ss2022/allowlist.txt 2>/dev/null || true)"
if [ "${SS2022_ALLOWED_COUNT:-0}" -gt 0 ]; then
  green "SS2022_TCP_READY_ALLOWLIST_COUNT=$SS2022_ALLOWED_COUNT"
else
  warn "SS2022_TCP_WAITING_ALLOWLIST — use client menu [19] to detect and explicitly approve the current public IPv4"
fi

step "FINAL CREDENTIAL HANDOFF"
bash "$ROOT/linux/03d-export-panel-handoff.sh" "$NODE_MODE" || true
if [ "$GRAY_ROUTE" -eq 1 ] || [ "$ROUTE_MODE" = keep ]; then
  bash "$ROOT/linux/04e-export-reality-handoff.sh" "$PUBLIC_IP" || true
fi
if [ "$GRAY_ROUTE" -eq 1 ]; then
  handoff_set "COVER_DOMAIN" "$GRAY_DOMAIN"
elif [ "$ROUTE_MODE" = keep ]; then
  RETAINED_COVER="$(sed -n 's/^COVER_DOMAIN=//p' "$PUBLIC_DIR/public.env" 2>/dev/null | sed -n '1p')"
  [ -z "$RETAINED_COVER" ] || handoff_set "COVER_DOMAIN" "$RETAINED_COVER"
fi
handoff_set "PUBLIC_IP_AT_HANDOFF" "$PUBLIC_IP"
handoff_set "SSH_PORT" "$SSH_PORT"
handoff_show

step "FINAL DOCTOR"
if [ "$ROUTE_MODE" != keep ]; then
  if command -v nginx >/dev/null 2>&1; then
    nginx -t
  else
    red "Nginx is required for the selected route mode."
    exit 1
  fi
else
  green "KEEP_ROUTE_FINAL_CHECK_SKIPPED: Nginx/route validation was not requested."
fi
if [ "$ROUTE_MODE" = keep ]; then
  systemctl enable x-ui fail2ban >/dev/null 2>&1 || true
else
  systemctl enable nginx x-ui fail2ban >/dev/null 2>&1 || true
fi
bash "$ROOT/linux/14-node-doctor.sh" || true

echo
green "AUTO_CONVERGENCE_FINISHED"
echo "Maintenance command:"
if command -v proxy-node >/dev/null 2>&1; then
  echo "  proxy-node"
else
  echo "  proxy-node (preferred; legacy compatibility command: text-node)"
fi
echo
echo "Route identities came only from this run's explicit input."
echo "No run-specific values were written back into the distributable toolkit."

RUN_COMPLETE=1
CURRENT_STAGE="COMPLETE"
write_run_status SUCCESS 0
cleanup_auto_input
trap - EXIT
