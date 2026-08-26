#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/linux/lib-deployment-state.sh"
MODE="${1:-}"
case "$MODE" in gray|orange|dual) ;; *) echo 'TNA_TOPOLOGY_ERROR=MODE_INVALID' >&2; exit 2;; esac
COMMIT_STATE="${2:-}"
case "$COMMIT_STATE" in ''|--commit-state) ;; *) echo 'TNA_TOPOLOGY_ERROR=ARGUMENT_INVALID' >&2; exit 2;; esac

ROLLBACK_DIR="$(mktemp -d /root/.tna-topology-rollback.XXXXXX)"
COMMITTED=0
snapshot_path() {
  local source="$1" name="$2"
  if [ -e "$source" ] || [ -L "$source" ]; then
    printf 'present\n' > "$ROLLBACK_DIR/${name}.presence"
    cp -a -- "$source" "$ROLLBACK_DIR/$name"
  else
    printf 'absent\n' > "$ROLLBACK_DIR/${name}.presence"
  fi
}
restore_path() {
  local target="$1" name="$2"
  rm -rf -- "$target"
  if grep -Fqx present "$ROLLBACK_DIR/${name}.presence" 2>/dev/null; then
    mkdir -p -- "$(dirname "$target")"
    cp -a -- "$ROLLBACK_DIR/$name" "$target"
  fi
}
rollback() {
  local rc="${1:-$?}"
  trap - ERR INT TERM
  if [ "$COMMITTED" -eq 0 ]; then
    set +e
    systemctl stop x-ui >/dev/null 2>&1
    restore_path /etc/x-ui x-ui
    restore_path /root/.config/text-node-assistant/cdn-xhttp.env cdn-xhttp.env
    restore_path /etc/nginx/sites-available/tna-cdn-xhttp-stage nginx-available
    restore_path /etc/nginx/sites-enabled/tna-cdn-xhttp-stage nginx-enabled
    restore_path /etc/nginx/conf.d/text-node-assistant-security-log.conf nginx-security-log
    restore_path /etc/text-node-assistant/cloudflare cloudflare
    restore_path /etc/text-node-assistant/deployment-state.env deployment-state.env
    restore_path /root/.config/text-node-assistant/topology.env topology.env
    systemctl start x-ui >/dev/null 2>&1
    nginx -t >/dev/null 2>&1 && systemctl reload nginx >/dev/null 2>&1
    echo "TNA_TOPOLOGY_ROLLED_BACK=1 rc=$rc" >&2
  fi
  rm -rf -- "$ROLLBACK_DIR"
  exit "$rc"
}
abort() {
  local message="$1" rc="$2"
  printf '%s\n' "$message" >&2
  rollback "$rc"
}
trap 'rollback $?' ERR
trap 'rollback 130' INT
trap 'rollback 143' TERM
trap 'rm -rf -- "$ROLLBACK_DIR"' EXIT

snapshot_path /etc/x-ui x-ui
snapshot_path /root/.config/text-node-assistant/cdn-xhttp.env cdn-xhttp.env
snapshot_path /etc/nginx/sites-available/tna-cdn-xhttp-stage nginx-available
snapshot_path /etc/nginx/sites-enabled/tna-cdn-xhttp-stage nginx-enabled
snapshot_path /etc/nginx/conf.d/text-node-assistant-security-log.conf nginx-security-log
snapshot_path /etc/text-node-assistant/cloudflare cloudflare
snapshot_path /etc/text-node-assistant/deployment-state.env deployment-state.env
snapshot_path /root/.config/text-node-assistant/topology.env topology.env

has_reality() { bash "$ROOT/linux/04a-reality-api.sh" inspect-443 >/dev/null 2>&1; }
has_xhttp() { bash "$ROOT/linux/04f-xhttp-cdn-api.sh" show >/dev/null 2>&1; }
edge_confirmed() { grep -Fqx 'CDN_REAL_CLIENT_CONFIRMED=1' /etc/text-node-assistant/cloudflare/edge-state.env 2>/dev/null; }
valid_domain() { [[ "${1:-}" =~ ^([A-Za-z0-9][A-Za-z0-9-]*\.)+[A-Za-z]{2,63}$ ]]; }

case "$MODE" in
  gray)
    has_reality || abort 'TNA_TOPOLOGY_ERROR=DIRECT_ROUTE_NOT_VERIFIED' 141
    bash "$ROOT/linux/05f-cloudflare-origin-lock.sh" remove >/dev/null 2>&1 || true
    bash "$ROOT/linux/05e-cdn-xhttp-nginx.sh" disable-stage
    bash "$ROOT/linux/04f-xhttp-cdn-api.sh" delete
    rm -rf -- /etc/text-node-assistant/cloudflare/candidate
    rm -f -- /etc/text-node-assistant/cloudflare/edge-state.env
    has_reality || abort 'TNA_TOPOLOGY_ERROR=DIRECT_ROUTE_LOST_AFTER_RECONCILE' 141
    ! has_xhttp || abort 'TNA_TOPOLOGY_ERROR=CDN_ROUTE_REMAINS' 141
    tna_state_commit_converged direct-reality ACTIVE_DIRECT xray-reality previously-exposed
    ;;
  orange)
    has_xhttp || abort 'TNA_TOPOLOGY_ERROR=CDN_ROUTE_NOT_VERIFIED' 142
    edge_confirmed || abort 'TNA_TOPOLOGY_ERROR=REAL_CLIENT_NOT_CONFIRMED' 142
    bash "$ROOT/linux/04a-reality-api.sh" delete-production
    ufw --force delete allow 443/tcp >/dev/null 2>&1 || true
    ! has_reality || abort 'TNA_TOPOLOGY_ERROR=DIRECT_ROUTE_REMAINS' 142
    has_xhttp || abort 'TNA_TOPOLOGY_ERROR=CDN_ROUTE_LOST_AFTER_RECONCILE' 142
    edge_confirmed || abort 'TNA_TOPOLOGY_ERROR=EDGE_CONFIRMATION_LOST' 142
    tna_state_commit_converged cdn-xhttp-tls ACTIVE_CDN none previously-exposed
    ;;
  dual)
    has_reality || abort 'TNA_TOPOLOGY_ERROR=DIRECT_ROUTE_NOT_VERIFIED' 143
    has_xhttp || abort 'TNA_TOPOLOGY_ERROR=CDN_ROUTE_NOT_VERIFIED' 143
    edge_confirmed || abort 'TNA_TOPOLOGY_ERROR=REAL_CLIENT_NOT_CONFIRMED' 143
    tna_state_commit_converged dual-hot-switch DUAL_INSTALLED_ACTIVE_CDN xray-reality previously-exposed
    ;;
esac

if [ "$COMMIT_STATE" = --commit-state ]; then
  install -d -m 700 /root/.config/text-node-assistant
  topology_tmp="$(mktemp /root/.config/text-node-assistant/.topology.XXXXXX)"
  cat > "$topology_tmp"
  awk -F= '
    BEGIN { ok=1 }
    $0 ~ /\r/ || NF < 2 { ok=0; next }
    $1 !~ /^(TOPOLOGY_STATE_VERSION|TOPOLOGY_MODE|GRAY_DOMAIN|GRAY_EMAIL|ORANGE_DOMAIN|ORANGE_EMAIL)$/ { ok=0 }
    seen[$1]++ > 0 { ok=0 }
    END {
      required["TOPOLOGY_STATE_VERSION"]=1; required["TOPOLOGY_MODE"]=1;
      required["GRAY_DOMAIN"]=1; required["GRAY_EMAIL"]=1;
      required["ORANGE_DOMAIN"]=1; required["ORANGE_EMAIL"]=1;
      for (key in required) if (seen[key] != 1) ok=0;
      exit ok ? 0 : 1
    }
  ' "$topology_tmp" || abort 'TNA_TOPOLOGY_ERROR=STATE_FORMAT_INVALID' 144
  grep -Fqx 'TOPOLOGY_STATE_VERSION=1' "$topology_tmp" || abort 'TNA_TOPOLOGY_ERROR=STATE_VERSION_INVALID' 144
  grep -Fqx "TOPOLOGY_MODE=$MODE" "$topology_tmp" || abort 'TNA_TOPOLOGY_ERROR=STATE_MODE_MISMATCH' 144
  gray_domain="$(sed -n 's/^GRAY_DOMAIN=//p' "$topology_tmp")"
  orange_domain="$(sed -n 's/^ORANGE_DOMAIN=//p' "$topology_tmp")"
  case "$MODE" in
    gray) valid_domain "$gray_domain" || abort 'TNA_TOPOLOGY_ERROR=GRAY_DOMAIN_INVALID' 144 ;;
    orange) valid_domain "$orange_domain" || abort 'TNA_TOPOLOGY_ERROR=ORANGE_DOMAIN_INVALID' 144 ;;
    dual)
      valid_domain "$gray_domain" && valid_domain "$orange_domain" && [ "$gray_domain" != "$orange_domain" ] || {
        abort 'TNA_TOPOLOGY_ERROR=DUAL_DOMAINS_INVALID' 144
      }
      ;;
  esac
  chmod 600 "$topology_tmp"
  mv -f -- "$topology_tmp" /root/.config/text-node-assistant/topology.env
fi

COMMITTED=1
printf 'TNA_TOPOLOGY_RECONCILED=1\nTOPOLOGY_MODE=%s\n' "$MODE"
