#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/linux/lib-gui-prompt.sh"
. "$ROOT/linux/lib-third-party.sh"
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
COVER_TEMPLATE_CHOICE="${PROXY_RUNBOOK_COVER_TEMPLATE:-auto}"

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
    [ -n "$v" ] || yellow "Required. There is intentionally no default."
  done
  printf '%s' "$v"
}

# Optional privacy-preserving auto-input file written by the Windows EXE.
AUTO_INPUT="${PROXY_RUNBOOK_AUTO_INPUT:-}"
INPUT_DOMAIN=""
INPUT_EMAIL=""
if [ -n "$AUTO_INPUT" ] && [ -r "$AUTO_INPUT" ]; then
  DB64="$(sed -n 's/^DOMAIN_B64=//p' "$AUTO_INPUT" | sed -n '1p')"
  EB64="$(sed -n 's/^EMAIL_B64=//p' "$AUTO_INPUT" | sed -n '1p')"
  LB="$(sed -n 's/^LANG=//p' "$AUTO_INPUT" | sed -n '1p')"
  [ -n "$DB64" ] && INPUT_DOMAIN="$(printf '%s' "$DB64" | base64 -d 2>/dev/null || true)"
  [ -n "$EB64" ] && INPUT_EMAIL="$(printf '%s' "$EB64" | base64 -d 2>/dev/null || true)"
  [ "$LB" = "zh" ] || [ "$LB" = "en" ] && RUN_LANG="$LB"
  rm -f "$AUTO_INPUT"
fi

[ "$(id -u)" -eq 0 ] || { red "Run as root/sudo."; exit 1; }
. /etc/os-release
case "${ID:-}" in
  ubuntu|debian) ;;
  *) red "Adaptive AUTO currently supports Ubuntu/Debian only. Detected: ${ID:-unknown}"; exit 1 ;;
esac

# v0.9.5: capture the pre-convergence state once, before package,
# service, firewall, panel, cover, WARP, or performance changes.  Older nodes
# that already carry runbook markers are labelled LEGACY_UNCERTAIN instead of
# pretending their current state is the original baseline.
bash "$ROOT/linux/22-dismantle-managed-node.sh" --capture-baseline

PUBLIC_IP="$(curl -4fsS --max-time 10 https://api.ipify.org 2>/dev/null || true)"
[ -n "$PUBLIC_IP" ] || PUBLIC_IP="$(hostname -I | awk '{print $1}')"
SSH_PORT="$(sshd -T 2>/dev/null | awk '$1=="port" && !found {print $2; found=1}')"
SSH_PORT="${SSH_PORT:-22}"
LOGIN_USER="${PROXY_RUNBOOK_LOGIN_USER:-${SUDO_USER:-root}}"
SSH_SOURCE="${SSH_CONNECTION%% *}"

step "STABLE NODE IDENTITY"
bash "$ROOT/linux/23-node-identity.sh" --init

EXISTING=0
NODE_MODE="FRESH"
if [ -x /usr/local/x-ui/x-ui ] || systemctl list-unit-files 2>/dev/null | grep '^x-ui\.service' >/dev/null; then
  EXISTING=1
  NODE_MODE="EXISTING"
fi

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
  PRE443="$(ss -lntp 2>/dev/null | grep -E ':443[[:space:]]' || true)"
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

# User explicitly required these to be human-entered every deployment/run.
step "HUMAN-ONLY REQUIRED INPUTS"
if [ -n "$INPUT_DOMAIN" ]; then
  DOMAIN="$INPUT_DOMAIN"
else
  if [ "$RUN_LANG" = "zh" ]; then
    DOMAIN="$(required "请亲自输入 Cover 域名，例如 cover.example.com")"
  else
    DOMAIN="$(required "Type the cover domain yourself, for example cover.example.com")"
  fi
fi
while ! [[ "$DOMAIN" =~ ^([A-Za-z0-9][A-Za-z0-9-]*\.)+[A-Za-z]{2,63}$ ]]; do
  yellow "Invalid cover domain."
  DOMAIN="$(required "Re-type cover domain")"
done

if [ -n "$INPUT_EMAIL" ]; then
  ACME_EMAIL="$INPUT_EMAIL"
else
  if [ "$RUN_LANG" = "zh" ]; then
    ACME_EMAIL="$(required "请亲自输入 Let's Encrypt 邮箱")"
  else
    ACME_EMAIL="$(required "Type the Let's Encrypt email yourself")"
  fi
fi
while ! [[ "$ACME_EMAIL" =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]]; do
  yellow "Invalid email address."
  ACME_EMAIL="$(required "Re-type Let's Encrypt email")"
done

echo
echo "You entered:"
echo "  COVER_DOMAIN=$DOMAIN"
echo "  ACME_EMAIL=$ACME_EMAIL"
yesq "Continue using exactly these values?" || exit 0

if [ "$EXISTING" -eq 1 ]; then
  step "BACKUP BEFORE EXISTING-NODE CHANGES"
  bash "$ROOT/linux/01-safe-backup.sh"
fi

step "BASE PACKAGES"
MISSING_BASE=()
for cmd in curl wget jq openssl ufw tcpdump nginx certbot fail2ban-client zip unzip sudo; do
  command -v "$cmd" >/dev/null 2>&1 || MISSING_BASE+=("$cmd")
done
if [ "${#MISSING_BASE[@]}" -gt 0 ]; then
  yellow "Missing base commands: ${MISSING_BASE[*]}"
  apt-get update
  apt-get install -y curl wget ca-certificates gnupg lsb-release jq openssl \
    ufw tcpdump nginx certbot python3-certbot-nginx fail2ban zip unzip sudo
else
  green "BASE_PACKAGES_ALREADY_PRESENT — skipped apt update/install"
fi
systemctl enable --now nginx fail2ban
green "BASE_OK"

step "ADAPTIVE PERFORMANCE PROFILE"
bash "$ROOT/linux/20-adaptive-performance.sh" --detect
if yesq "Apply the rollback-capable hardware-adaptive performance profile now?"; then
  bash "$ROOT/linux/20-adaptive-performance.sh" --apply auto
else
  yellow "Adaptive performance changes were skipped. Menu [16] can apply them later."
fi

step "FIREWALL BASELINE"
ufw allow "${SSH_PORT}/tcp"
ufw allow 80/tcp
ufw allow 443/tcp
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
remove_public_rule_for_port 8443
remove_public_rule_for_port 40000

step "MANAGED SSH SECURITY BASELINE"
bash "$ROOT/linux/24-security-baseline.sh" --apply 7
green "FAIL2BAN_SSHD_JAIL_VERIFIED"

step "3X-UI"
XUI="/usr/local/x-ui/x-ui"
if [ "$EXISTING" -eq 0 ]; then
  if yesq "Install official stable 3x-ui unattended with UNIQUE RANDOM credentials?"; then
    export XUI_NONINTERACTIVE=1
    export XUI_SSL_MODE=none
    export XUI_DB_TYPE=sqlite
    # Intentionally do NOT set username/password/panel port/web path:
    # the pinned official installer generates unique random values.
    pna_install_3xui_pinned "$ROOT"
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
  local tmp
  tmp="$(mktemp)"
  cat > "$tmp" <<EOF
PUBLIC_IP=$PUBLIC_IP
SSH_PORT=$SSH_PORT
PANEL_PORT=$PANEL_PORT
WEB_BASE_PATH=$RAW_PATH
COVER_DOMAIN=$DOMAIN
REALITY_TARGET=127.0.0.1:8443
WARP_PROXY_PORT=40000
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

step "DNS FOR THE HUMAN-TYPED DOMAIN"
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

step "NGINX + LET'S ENCRYPT + LOCALHOST:8443"
TLS_OK=0
if [ -f "/etc/letsencrypt/live/${DOMAIN}/fullchain.pem" ] && \
   ss -lntp 2>/dev/null | grep '127.0.0.1:8443' >/dev/null && \
   nginx -t >/dev/null 2>&1; then
  if curl -fsS --max-time 10 --resolve "${DOMAIN}:8443:127.0.0.1" \
       "https://${DOMAIN}:8443/" >/dev/null 2>&1; then
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

step "WARP / MASQUE LOCAL PROXY"
WARP_OK=0
if command -v warp-cli >/dev/null 2>&1 && systemctl is-active --quiet warp-svc 2>/dev/null; then
  TRACE="$(curl -fsS --max-time 20 --proxy socks5h://127.0.0.1:40000 \
    https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null || true)"
  if grep -q '^warp=on$' <<<"$TRACE" && ss -lntp 2>/dev/null | grep '127.0.0.1:40000' >/dev/null; then
    WARP_OK=1
  fi
fi
if [ "$WARP_OK" -eq 1 ]; then
  green "WARP_PROXY_ALREADY_OPTIMAL"
else
  if yesq "Install/normalize WARP Local Proxy using MASQUE on localhost:40000?"; then
    command -v warp-cli >/dev/null 2>&1 || bash "$ROOT/linux/06-warp-install.sh"
    bash "$ROOT/linux/07-warp-configure-proxy.sh" 40000
    WARP_OK=1
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

step "REALITY 443"
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
  if yesq "No VLESS+REALITY 443 exists. Create a safe 24443 shadow first?"; then
    if EXISTING_SHADOW="$(bash "$ROOT/linux/04a-reality-api.sh" show-shadow 24443 2>/dev/null)"; then
      printf '%s\n' "$EXISTING_SHADOW"
      green "EXISTING_24443_SHADOW_REUSED"
    else
      bash "$ROOT/linux/04a-reality-api.sh" create-test "$DOMAIN" "$PUBLIC_IP" 24443
    fi
    if [ -n "${SSH_SOURCE:-}" ]; then
      ufw allow from "$SSH_SOURCE" to any port 24443 proto tcp comment 'proxy-runbook-reality-shadow'
    else
      yellow "Could not infer SSH source IP; 24443 was not opened automatically."
    fi
    echo
    yellow "Import the printed 24443 vless:// link into your client and REALLY browse through it."
    if human_yesq "你已经亲自把 24443 链接导入客户端，并确认能正常上网了吗？" "Have you personally imported the 24443 link and verified real browsing works?"; then
      bash "$ROOT/linux/04a-reality-api.sh" promote-shadow 24443 443
      mapfile -t N < <(ufw status numbered | grep '24443' | grep 'proxy-runbook-reality-shadow' \
        | sed -n 's/^\[[[:space:]]*\([0-9]\+\)\].*/\1/p' | sort -rn)
      for n in "${N[@]:-}"; do [ -n "$n" ] && yes | ufw delete "$n" >/dev/null || true; done
      green "PRODUCTION_443_CREATED"
    else
      yellow "Production 443 was not created. Shadow remains for debugging."
      exit 3
    fi
  fi
else
  yellow "Existing 443 differs from the local self-steal profile for the domain YOU typed."
  yellow "Direct rewrite is forbidden. Only a 24443 clone/test/commit path is allowed."
  if yesq "Create an optimized 24443 clone of existing 443 for A/B testing?"; then
    bash "$ROOT/linux/04d-optimize-existing-reality-shadow.sh" prepare "$DOMAIN" "$PUBLIC_IP" 24443
    echo
    yellow "Import a TEST link above. Save the FUTURE 443 link(s) too."
    if human_yesq "你已经亲自确认 24443 正常，并保存了未来 443 链接吗？" "Have you personally verified 24443 and saved the future 443 link(s)?"; then
      bash "$ROOT/linux/04d-optimize-existing-reality-shadow.sh" commit "$DOMAIN" "$PUBLIC_IP" 24443
      green "EXISTING_REALITY_CONVERGED"
    else
      if noq "Delete the temporary shadow now?"; then
        bash "$ROOT/linux/04d-optimize-existing-reality-shadow.sh" abort "$DOMAIN" "$PUBLIC_IP" 24443
      else
        yellow "Shadow left for later; production 443 unchanged."
      fi
    fi
  fi
fi

if [ "$WARP_OK" -eq 1 ]; then
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
    elif yesq "Add persistent OpenAI/ChatGPT -> WARP route while preserving unrelated Xray config?"; then
      bash "$ROOT/linux/07a-apply-warp-route-local.sh" 40000
    fi
  fi
fi

step "FINAL CREDENTIAL HANDOFF"
bash "$ROOT/linux/03d-export-panel-handoff.sh" "$NODE_MODE" || true
bash "$ROOT/linux/04e-export-reality-handoff.sh" "$PUBLIC_IP" || true
handoff_set "COVER_DOMAIN" "$DOMAIN"
handoff_set "PUBLIC_IP_AT_HANDOFF" "$PUBLIC_IP"
handoff_set "SSH_PORT" "$SSH_PORT"
handoff_show

step "FINAL DOCTOR"
nginx -t
systemctl enable nginx x-ui fail2ban >/dev/null 2>&1 || true
[ ! -x /usr/local/lib/proxy-node-assistant/security-firewall.sh ] || \
  /usr/local/lib/proxy-node-assistant/security-firewall.sh restart || true
bash "$ROOT/linux/14-node-doctor.sh" || true

echo
green "AUTO_CONVERGENCE_FINISHED"
echo "Maintenance command:"
echo "  proxy-node"
echo
echo "The cover domain and email came only from your manual input."
echo "No run-specific values were written back into the distributable toolkit."

RUN_COMPLETE=1
CURRENT_STAGE="COMPLETE"
write_run_status SUCCESS 0
trap - EXIT
