#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/linux/lib-deployment-state.sh"

XHTTP_STATE="/root/.config/text-node-assistant/cdn-xhttp.env"
NGINX_AVAILABLE="/etc/nginx/sites-available/tna-cdn-xhttp-stage"
NGINX_ENABLED="/etc/nginx/sites-enabled/tna-cdn-xhttp-stage"
CANDIDATE_DIR="/etc/text-node-assistant/candidates"
SECURITY_LOG_CONF="/etc/nginx/conf.d/text-node-assistant-security-log.conf"
SECURITY_LOG_MARKER="# TNA_MANAGED_NGINX_SECURITY_LOG_V095"

[ "$(id -u)" -eq 0 ] || { echo 'ERROR: run as root.' >&2; exit 1; }
TARGET_TOPOLOGY="${TNA_TARGET_TOPOLOGY:-dual}"
case "$TARGET_TOPOLOGY" in orange|dual) ;; *) echo 'TNA_CDN_NGINX_ERROR=TARGET_TOPOLOGY_INVALID' >&2; exit 108;; esac

reality_443_present() {
  ss -H -lntp 2>/dev/null | grep -E ':[4]43[[:space:]].*[x]ray' >/dev/null
}

state_value() {
  local key="$1" line
  [ -r "$XHTTP_STATE" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in "${key}="*) printf '%s\n' "${line#*=}"; return 0;; esac
  done < "$XHTTP_STATE"
  return 1
}
valid_domain() { [[ "${1:-}" =~ ^([A-Za-z0-9][A-Za-z0-9-]*\.)+[A-Za-z]{2,63}$ ]]; }
valid_ipv4() {
  local value="$1" part
  [[ "$value" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
  IFS=. read -r -a parts <<<"$value"
  [ "${#parts[@]}" -eq 4 ] || return 1
  for part in "${parts[@]}"; do [ "$part" -ge 0 ] 2>/dev/null && [ "$part" -le 255 ] || return 1; done
}

render_server() {
  local listen_line="$1" domain="$2" local_port="$3" path="$4"
  cat <<EOF
# TNA_MANAGED_CDN_XHTTP_V095
server {
    ${listen_line}
    server_name ${domain};
    server_tokens off;
    access_log /var/log/nginx/text-node-assistant-security.log tna_security;

    ssl_certificate /etc/letsencrypt/live/${domain}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${domain}/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_session_cache shared:tna_cdn_xhttp_ssl:10m;
    ssl_session_timeout 1d;
    ssl_session_tickets off;

    root /var/www/cover;
    index index.html;
    add_header X-TNA-Managed-Origin "cdn-xhttp-v095" always;
    add_header X-TNA-Origin-Port "8443" always;

    location ^~ ${path} {
        proxy_pass http://127.0.0.1:${local_port};
        proxy_http_version 1.1;
        proxy_redirect off;
        proxy_request_buffering off;
        proxy_buffering off;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
        proxy_set_header Host \$host;
        proxy_set_header X-Forwarded-Proto https;
        proxy_set_header X-Forwarded-For \$http_cf_connecting_ip;
        add_header Cache-Control "no-store" always;
    }

    location /assets/ {
        try_files \$uri =404;
        expires 7d;
        add_header Cache-Control "public, max-age=604800, immutable";
    }
    error_page 404 /404.html;
    location = /404.html { internal; }
    location / { try_files \$uri \$uri/ =404; }
}
EOF
}

ensure_security_logging() {
  local path="$1" tmp
  if [ -e "$SECURITY_LOG_CONF" ] && ! grep -Fqx "$SECURITY_LOG_MARKER" "$SECURITY_LOG_CONF" 2>/dev/null; then
    echo 'TNA_CDN_NGINX_ERROR=UNMANAGED_SECURITY_LOG_CONFIG' >&2
    return 110
  fi
  tmp="$(mktemp /etc/nginx/conf.d/.tna-security-log.XXXXXX)"
  cat > "$tmp" <<EOF
$SECURITY_LOG_MARKER
map \$uri \$tna_route_class {
    default web;
    ~^/\\.well-known/acme-challenge/ acme;
    "${path}" xhttp;
}
log_format tna_security 'epoch=\$msec client_ip=\$remote_addr edge_ip=\$realip_remote_addr method=\$request_method route_class=\$tna_route_class status=\$status bytes=\$body_bytes_sent cf_ray=\$http_cf_ray';
EOF
  install -m 640 -o root -g www-data "$tmp" "$SECURITY_LOG_CONF"
  rm -f "$tmp"
}

load_values() {
  DOMAIN="$1"
  PUBLIC_IP="$2"
  valid_domain "$DOMAIN" || { echo 'TNA_CDN_NGINX_ERROR=DOMAIN_INVALID' >&2; return 111; }
  valid_ipv4 "$PUBLIC_IP" || { echo 'TNA_CDN_NGINX_ERROR=PUBLIC_IP_INVALID' >&2; return 111; }
  LOCAL_PORT="$(state_value XHTTP_LOCAL_PORT || true)"
  XHTTP_PATH="$(state_value XHTTP_PATH || true)"
  case "$LOCAL_PORT" in ''|*[!0-9]*) echo 'TNA_CDN_NGINX_ERROR=XHTTP_PORT_MISSING' >&2; return 112;; esac
  [[ "$XHTTP_PATH" =~ ^/[0-9a-f]{32}/$ ]] || { echo 'TNA_CDN_NGINX_ERROR=XHTTP_PATH_INVALID' >&2; return 112; }
  [ -s "/etc/letsencrypt/live/${DOMAIN}/fullchain.pem" ] && [ -s "/etc/letsencrypt/live/${DOMAIN}/privkey.pem" ] || {
    echo 'TNA_CDN_NGINX_ERROR=CERTIFICATE_MISSING' >&2; return 113;
  }
}

stage() {
  local domain="$1" public_ip="$2" local_only="${3:-0}" tmp backup='' listener listen_address listen_lines probe_address current
  load_values "$domain" "$public_ip"
  if [ "$local_only" = 1 ]; then
    listen_address='127.0.0.2'
    listen_lines='listen 127.0.0.2:8443 ssl http2;'
    probe_address='127.0.0.2'
  else
    # Never bind 0.0.0.0 here: the managed cover backend already owns
    # 127.0.0.1:8443. Bind the concrete origin address and retain the
    # 127.0.0.2 listener for local TLS validation instead.
    listen_address="$PUBLIC_IP"
    listen_lines="$(printf 'listen %s:8443 ssl http2;\n    listen 127.0.0.2:8443 ssl http2;' "$PUBLIC_IP")"
    probe_address='127.0.0.2'
    ufw status 2>/dev/null | grep -q '^Status: active$' || { echo 'TNA_CDN_NGINX_ERROR=UFW_INACTIVE' >&2; return 114; }
    ufw status verbose 2>/dev/null | grep -q '^Default: deny (incoming)' || { echo 'TNA_CDN_NGINX_ERROR=UFW_INCOMING_NOT_DENY' >&2; return 114; }
    grep -q '^CLOUDFLARE_FIREWALL_APPLIED=1$' /etc/text-node-assistant/cloudflare/cidr-state.env 2>/dev/null || {
      echo 'TNA_CDN_NGINX_ERROR=CLOUDFLARE_ORIGIN_LOCK_NOT_APPLIED' >&2; return 114;
    }
  fi
  listener="$(ss -lntp 2>/dev/null | awk -v address="${listen_address}:8443" '$4 == address {print; exit}')"
  if [ -n "$listener" ] && ! grep -qF '# TNA_MANAGED_CDN_XHTTP_V095' "$NGINX_AVAILABLE" 2>/dev/null; then
    echo "TNA_CDN_NGINX_ERROR=PUBLIC_8443_OWNED_BY_UNKNOWN listener=$listener" >&2
    return 114
  fi
  if [ -f "$NGINX_AVAILABLE" ]; then
    backup="${NGINX_AVAILABLE}.tna-rollback"
    cp -a -- "$NGINX_AVAILABLE" "$backup"
  fi
  ensure_security_logging "$XHTTP_PATH"
  tmp="$(mktemp /etc/nginx/sites-available/.tna-cdn-xhttp-stage.XXXXXX)"
  render_server "$listen_lines" "$DOMAIN" "$LOCAL_PORT" "$XHTTP_PATH" > "$tmp"
  chmod 644 "$tmp"
  mv -f -- "$tmp" "$NGINX_AVAILABLE"
  ln -sfn "$NGINX_AVAILABLE" "$NGINX_ENABLED"
  if ! nginx -t; then
    rm -f -- "$NGINX_ENABLED"
    if [ -n "$backup" ]; then cp -a -- "$backup" "$NGINX_AVAILABLE"; else rm -f -- "$NGINX_AVAILABLE"; fi
    nginx -t >/dev/null 2>&1 || true
    echo 'TNA_CDN_NGINX_ERROR=CONFIG_TEST_FAILED_ROLLED_BACK' >&2
    return 115
  fi
  systemctl reload nginx
  for _ in $(seq 1 40); do
    ss -lntp 2>/dev/null | awk -v address="${listen_address}:8443" '$4 == address {found=1} END{exit found ? 0 : 1}' && break
    sleep 0.25
  done
  ss -lntp 2>/dev/null | awk -v address="${listen_address}:8443" '$4 == address {found=1} END{exit found ? 0 : 1}' || {
    echo 'TNA_CDN_NGINX_ERROR=STAGE_LISTENER_MISSING' >&2; return 116;
  }
  curl --fail --silent --show-error --max-time 10 --resolve "${DOMAIN}:8443:${probe_address}" "https://${DOMAIN}:8443/" >/dev/null || {
    echo 'TNA_CDN_NGINX_ERROR=LOCAL_STAGE_TLS_PROBE_FAILED' >&2; return 117;
  }
  current="$(tna_state_env_value ACTIVE_MODE || true)"
  if [ "$TARGET_TOPOLOGY" = orange ] && ! reality_443_present; then
    # A fresh orange-only node must never fabricate an ACTIVE_DIRECT/Reality
    # state merely to reuse the dual-route staging code.
    case "$current" in
      ''|ACTIVE_CDN)
        tna_state_commit_converged cdn-xhttp-tls CDN_STAGED_8443 none clean
        ;;
      CDN_STAGED_8443|WAITING_FOR_CLOUDFLARE_MANUAL_ACTION|SWITCH_TO_CDN_STAGED_8443) ;;
      *) echo "TNA_CDN_NGINX_ERROR=ORANGE_STATE_NOT_STAGEABLE_${current}" >&2; return 118 ;;
    esac
  else
    reality_443_present || { echo 'TNA_CDN_NGINX_ERROR=DUAL_TARGET_REQUIRES_REALITY_443' >&2; return 118; }
    if [ -z "$current" ]; then
      tna_state_commit_converged direct-reality ACTIVE_DIRECT xray-reality previously-exposed
      current=ACTIVE_DIRECT
    fi
    case "$current" in
      ACTIVE_DIRECT) tna_state_transition ACTIVE_DIRECT CDN_STAGED_8443 cdn-xhttp-tls xray-reality previously-exposed ;;
      CDN_STAGED_8443) ;;
      ACTIVE_CDN) tna_state_commit_converged dual-hot-switch SWITCH_TO_CDN_STAGED_8443 xray-reality previously-exposed ;;
      DUAL_INSTALLED_ACTIVE_DIRECT) tna_state_transition DUAL_INSTALLED_ACTIVE_DIRECT SWITCH_TO_CDN_STAGED_8443 dual-hot-switch xray-reality previously-exposed ;;
      SWITCH_TO_CDN_STAGED_8443|WAITING_FOR_CLOUDFLARE_MANUAL_ACTION|DUAL_INSTALLED_ACTIVE_DIRECT|DUAL_INSTALLED_ACTIVE_CDN) ;;
      *) echo "TNA_CDN_NGINX_ERROR=STATE_NOT_STAGEABLE_${current}" >&2; return 118 ;;
    esac
  fi
  printf '__TNA_CDN_NGINX_BEGIN__\n'
  printf 'CDN_NGINX_STATUS=STAGED\nCDN_STAGE_LISTEN=%s:8443\nCDN_STAGE_SCOPE=%s\nCDN_XHTTP_UPSTREAM=127.0.0.1:%s\nCDN_XHTTP_PATH=%s\nCLOUDFLARE_API_MUTATION=NONE\n' \
    "$listen_address" "$([ "$local_only" = 1 ] && printf LOCAL_ONLY || printf CLOUDFLARE_ONLY)" "$LOCAL_PORT" "$XHTTP_PATH"
  printf '__TNA_CDN_NGINX_END__\n'
}

prepare_production() {
  load_values "$1" "$2"
  install -d -m 700 "$CANDIDATE_DIR"
  render_server "$(printf 'listen %s:8443 ssl http2;\n    listen 127.0.0.2:8443 ssl http2;' "$PUBLIC_IP")" "$DOMAIN" "$LOCAL_PORT" "$XHTTP_PATH" > "$CANDIDATE_DIR/cdn-xhttp-production.conf"
  chmod 600 "$CANDIDATE_DIR/cdn-xhttp-production.conf"
  sha256sum "$CANDIDATE_DIR/cdn-xhttp-production.conf" > "$CANDIDATE_DIR/cdn-xhttp-production.conf.sha256"
  chmod 600 "$CANDIDATE_DIR/cdn-xhttp-production.conf.sha256"
  echo 'TNA_CDN_PRODUCTION_CANDIDATE_READY'
  echo 'TNA_CDN_PRODUCTION_ORIGIN_PORT=8443'
  echo 'TNA_CDN_EDGE_PORT=8443'
  echo 'TNA_CDN_ORIGIN_PORT=8443'
  echo 'TNA_CDN_PRODUCTION_NOT_ENABLED=WAITING_FOR_REAL_DEVICE_CONFIRMATION'
}

disable_stage() {
  [ -e "$NGINX_AVAILABLE" ] || { echo 'TNA_CDN_STAGE_NOT_INSTALLED'; return 0; }
  grep -qF '# TNA_MANAGED_CDN_XHTTP_V095' "$NGINX_AVAILABLE" || { echo 'TNA_CDN_NGINX_ERROR=UNMANAGED_STAGE_CONFIG' >&2; return 119; }
  rm -f -- "$NGINX_ENABLED" "$NGINX_AVAILABLE"
  if grep -Fqx "$SECURITY_LOG_MARKER" "$SECURITY_LOG_CONF" 2>/dev/null; then
    rm -f -- "$SECURITY_LOG_CONF"
  fi
  rm -f -- /etc/text-node-assistant/cloudflare/edge-state.env
  nginx -t
  systemctl reload nginx
  echo 'TNA_CDN_STAGE_DISABLED'
}

case "${1:-}" in
  stage) [ "$#" -eq 3 ] || { echo 'usage: stage DOMAIN PUBLIC_IP' >&2; exit 2; }; stage "$2" "$3" ;;
  stage-local) [ "$#" -eq 3 ] || { echo 'usage: stage-local DOMAIN PUBLIC_IP' >&2; exit 2; }; stage "$2" "$3" 1 ;;
  prepare-production) [ "$#" -eq 3 ] || { echo 'usage: prepare-production DOMAIN PUBLIC_IP' >&2; exit 2; }; prepare_production "$2" "$3" ;;
  disable-stage) [ "$#" -eq 1 ] || exit 2; disable_stage ;;
  *) echo 'usage: 05e-cdn-xhttp-nginx.sh stage DOMAIN PUBLIC_IP | stage-local DOMAIN PUBLIC_IP | prepare-production DOMAIN PUBLIC_IP | disable-stage' >&2; exit 2 ;;
esac
