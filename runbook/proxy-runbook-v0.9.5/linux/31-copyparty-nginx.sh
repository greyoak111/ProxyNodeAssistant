#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEMPLATE="$ROOT/templates/nginx/proxy-node-assistant-copyparty.conf.in"
CANDIDATE_DIR=/etc/proxy-runbook/candidates
AVAILABLE=/etc/nginx/sites-available/pna-private-drive
ENABLED=/etc/nginx/sites-enabled/pna-private-drive

[ "$(id -u)" -eq 0 ] || { echo 'PNA_DRIVE_NGINX_ERROR=ROOT_REQUIRED' >&2; exit 151; }
valid_hostname() { [[ "${1:-}" =~ ^([A-Za-z0-9][A-Za-z0-9-]*\.)+[A-Za-z]{2,63}$ ]]; }
valid_port() { case "${1:-}" in 2053|2083|2087|2096) return 0;; *) return 1;; esac; }

render() {
  local hostname="$1" port="$2" address="$3" destination="$4" tmp
  valid_hostname "$hostname" || { echo 'PNA_DRIVE_NGINX_ERROR=HOSTNAME_INVALID' >&2; return 152; }
  valid_port "$port" || { echo 'PNA_DRIVE_NGINX_ERROR=PORT_NOT_ALLOWLISTED' >&2; return 152; }
  tmp="$(mktemp "$(dirname "$destination")/.pna-drive-nginx.XXXXXX")"
  sed -e "s|@DRIVE_HOSTNAME@|${hostname}|g" -e "s|@ORIGIN_PORT@|${port}|g" -e "s|@LISTEN_ADDRESS@|${address}|g" "$TEMPLATE" > "$tmp"
  grep -qF '# PNA_MANAGED_COPYPARTY_NGINX_V095' "$tmp" || { rm -f -- "$tmp"; return 153; }
  chmod 0600 "$tmp"
  mv -f -- "$tmp" "$destination"
}

prepare() {
  install -d -m 0700 "$CANDIDATE_DIR"
  render "$1" "$2" PUBLIC_IP_PLACEHOLDER "$CANDIDATE_DIR/private-drive-production.conf"
  sha256sum "$CANDIDATE_DIR/private-drive-production.conf" > "$CANDIDATE_DIR/private-drive-production.conf.sha256"
  chmod 0600 "$CANDIDATE_DIR/private-drive-production.conf.sha256"
  echo 'PNA_DRIVE_NGINX_CANDIDATE_READY'
  echo 'PNA_DRIVE_NGINX_NOT_ENABLED=WAITING_FOR_CLOUDFLARE_AND_CERTIFICATE'
}

stage_local() {
  local hostname="$1" port="$2"
  [ -s "/etc/letsencrypt/live/${hostname}/fullchain.pem" ] && [ -s "/etc/letsencrypt/live/${hostname}/privkey.pem" ] || {
    echo 'PNA_DRIVE_NGINX_ERROR=CERTIFICATE_MISSING' >&2; return 154;
  }
  systemctl is-active --quiet proxy-node-assistant-copyparty.service || { echo 'PNA_DRIVE_NGINX_ERROR=COPYPARTY_INACTIVE' >&2; return 154; }
  if [ -e "$AVAILABLE" ] && ! grep -qF '# PNA_MANAGED_COPYPARTY_NGINX_V095' "$AVAILABLE"; then
    echo 'PNA_DRIVE_NGINX_ERROR=UNMANAGED_CONFIG_EXISTS' >&2; return 155
  fi
  render "$hostname" "$port" 127.0.0.3 "$AVAILABLE"
  chmod 0644 "$AVAILABLE"
  ln -sfn "$AVAILABLE" "$ENABLED"
  nginx -t || { rm -f -- "$ENABLED" "$AVAILABLE"; return 156; }
  systemctl reload nginx
  ss -H -lntp 2>/dev/null | awk -v target="127.0.0.3:${port}" '$4 == target {found=1} END{exit found ? 0 : 1}' || {
    echo 'PNA_DRIVE_NGINX_ERROR=LOCAL_LISTENER_MISSING' >&2; return 157;
  }
  echo 'PNA_DRIVE_NGINX_LOCAL_STAGE_READY'
  echo 'PNA_DRIVE_PUBLIC_ACCESS=BLOCKED'
}

disable() {
  if [ -e "$AVAILABLE" ] && ! grep -qF '# PNA_MANAGED_COPYPARTY_NGINX_V095' "$AVAILABLE"; then
    echo 'PNA_DRIVE_NGINX_ERROR=UNMANAGED_CONFIG_EXISTS' >&2; return 155
  fi
  rm -f -- "$ENABLED" "$AVAILABLE"
  nginx -t
  systemctl reload nginx
  echo 'PNA_DRIVE_NGINX_DISABLED'
}

case "${1:-}" in
  prepare) [ "$#" -eq 3 ] || exit 2; prepare "$2" "$3" ;;
  stage-local) [ "$#" -eq 3 ] || exit 2; stage_local "$2" "$3" ;;
  disable) [ "$#" -eq 1 ] || exit 2; disable ;;
  *) echo 'usage: 31-copyparty-nginx.sh prepare HOSTNAME PORT | stage-local HOSTNAME PORT | disable' >&2; exit 2 ;;
esac
