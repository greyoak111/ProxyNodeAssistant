#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

STAMP="$(date +%Y%m%d-%H%M%S)"
STAGE="$(mktemp -d /root/.text-node-current-config.XXXXXX)"
VERIFY="$(mktemp -d /root/.verify-current-config.XXXXXX)"
PAYLOAD="$STAGE/current-config"
ARCHIVE="/root/text-node-current-config-${STAMP}.tar.gz"

cleanup_stage() {
  rm -rf -- "$STAGE" "$VERIFY"
}
trap cleanup_stage EXIT

service_snapshot() {
  local unit state
  for unit in x-ui nginx warp-svc ssh sshd; do
    state="$(systemctl is-active "$unit" 2>/dev/null || true)"
    printf '%s=%s\n' "$unit" "${state:-absent}"
  done
}

copy_path() {
  local src="$1" parent
  [ -e "$src" ] || return 0
  parent="$PAYLOAD$(dirname "$src")"
  mkdir -p "$parent"
  cp -a -- "$src" "$parent/"
}

services_before="$(service_snapshot)"
mkdir -p "$PAYLOAD"

# Current configuration and identity only. Do not copy the x-ui program tree,
# journals, service status dumps, or an expanded duplicate of the archive.
for src in \
  /etc/x-ui \
  /usr/local/x-ui/bin/config.json \
  /etc/nginx \
  /etc/letsencrypt \
  /etc/ufw \
  /etc/fail2ban \
  /etc/network/interfaces \
  /etc/netplan \
  /etc/sysctl.conf \
  /etc/sysctl.d \
  /etc/apt/sources.list.d/cloudflare-client.list \
  /var/lib/cloudflare-warp \
  /etc/text-node-assistant \
  /root/.config/text-node-assistant \
  /etc/ssh/sshd_config \
  /etc/ssh/sshd_config.d \
  /root/.ssh/authorized_keys \
  /etc/systemd/system/x-ui.service \
  /etc/systemd/system/nginx.service.d; do
  copy_path "$src"
done

# Historical WARP/Xray templates are managed backups, not current state. They
# are removed from the staging copy before the new archive is constructed.
find "$PAYLOAD/root/.config/text-node-assistant" -maxdepth 1 -type f \
  -name 'xray-template-before-warp-*.json' -delete 2>/dev/null || true

[ -s "$PAYLOAD/etc/x-ui/x-ui.db" ] || {
  echo 'ERROR: required current x-ui database is missing' >&2
  exit 31
}

mkdir -p "$PAYLOAD/runtime-config"
iptables-save > "$PAYLOAD/runtime-config/iptables.rules" 2>/dev/null || true
ip6tables-save > "$PAYLOAD/runtime-config/ip6tables.rules" 2>/dev/null || true
nft list ruleset > "$PAYLOAD/runtime-config/nft-ruleset.txt" 2>/dev/null || true
ip -4 route show table all > "$PAYLOAD/runtime-config/ip4-routes.txt" 2>/dev/null || true
ip -6 route show table all > "$PAYLOAD/runtime-config/ip6-routes.txt" 2>/dev/null || true

{
  printf 'PROXY_NODE_CURRENT_CONFIG_BACKUP=1\n'
  printf 'FORMAT_VERSION=1\n'
  printf 'CREATED_AT=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf 'HOSTNAME=%s\n' "$(hostname)"
} > "$PAYLOAD/BACKUP_INFO.txt"

(
  cd "$STAGE"
  find current-config -type f -print0 | sort -z | xargs -0 sha256sum > MANIFEST.sha256
  tar -czf "$ARCHIVE" current-config MANIFEST.sha256
)
chmod 600 "$ARCHIVE"

# Fully validate the new archive before any old backup is deleted.
gzip -t "$ARCHIVE"
tar -xzf "$ARCHIVE" -C "$VERIFY"
(
  cd "$VERIFY"
  sha256sum -c MANIFEST.sha256 >/dev/null
)
[ -s "$VERIFY/current-config/etc/x-ui/x-ui.db" ]
grep -Fxq 'PROXY_NODE_CURRENT_CONFIG_BACKUP=1' "$VERIFY/current-config/BACKUP_INFO.txt"
if find "$VERIFY/current-config" -type f \
  \( -name 'xray-template-before-warp-*.json' \
     -o -name 'text-node-backup-*' \
     -o -name 'nginx-cover-before-*' \
     -o -name 'cover-nginx-before-v*' \) -print -quit | grep -q .; then
  echo 'ERROR: a historical managed backup leaked into the current-config archive' >&2
  exit 36
fi

archive_size="$(stat -c %s "$ARCHIVE")"
archive_sha="$(sha256sum "$ARCHIVE" | awk '{print $1}')"

# The cleanup scope is deliberately limited to exact project-managed names.
# The new, already validated archive is explicitly excluded.
mapfile -d '' targets < <(
  {
    find /root -xdev -mindepth 1 -maxdepth 1 \
      \( -name 'text-node-backup-*' \
         -o -name 'text-node-current-config-*.tar.gz' \
         -o -name 'cover-site-before-*' \
         -o -name 'nginx-cover-before-*.conf' \
         -o -name 'cover-nginx-before-v*.conf' \
         -o -name 'iptables-before-restore-*.rules' \) \
      ! -path "$ARCHIVE" -print0
    find /root/.config/text-node-assistant -xdev -mindepth 1 -maxdepth 1 -type f \
      -name 'xray-template-before-warp-*.json' -print0 2>/dev/null || true
  }
)

removed_count=0
removed_bytes=0
for target in "${targets[@]}"; do
  case "$target" in
    /root/text-node-backup-*|\
    /root/text-node-current-config-*.tar.gz|\
    /root/cover-site-before-*|\
    /root/nginx-cover-before-*.conf|\
    /root/cover-nginx-before-v*.conf|\
    /root/iptables-before-restore-*.rules|\
    /root/.config/text-node-assistant/xray-template-before-warp-*.json)
      ;;
    *)
      echo 'ERROR: unsafe cleanup target rejected' >&2
      exit 32
      ;;
  esac
  size="$(du -sb -- "$target" 2>/dev/null | awk '{print $1}')"
  size="${size:-0}"
  removed_bytes=$((removed_bytes + size))
  rm -rf -- "$target"
  removed_count=$((removed_count + 1))
done

remaining="$({
  find /root -xdev -mindepth 1 -maxdepth 1 \
    \( -name 'text-node-backup-*' \
       -o -name 'cover-site-before-*' \
       -o -name 'nginx-cover-before-*.conf' \
       -o -name 'cover-nginx-before-v*.conf' \
       -o -name 'iptables-before-restore-*.rules' \) -print -quit
  find /root/.config/text-node-assistant -xdev -mindepth 1 -maxdepth 1 -type f \
    -name 'xray-template-before-warp-*.json' -print -quit 2>/dev/null || true
})"
[ -z "$remaining" ] || {
  echo 'ERROR: an old managed backup remains' >&2
  exit 33
}

current_count="$(find /root -xdev -mindepth 1 -maxdepth 1 -type f \
  -name 'text-node-current-config-*.tar.gz' | wc -l)"
[ "$current_count" -eq 1 ] || {
  echo "ERROR: expected one current-config archive, found $current_count" >&2
  exit 34
}

services_after="$(service_snapshot)"
[ "$services_after" = "$services_before" ] || {
  echo 'ERROR: service state changed during backup cleanup' >&2
  exit 35
}

printf 'CURRENT_CONFIG_BACKUP_OK\n'
printf 'ARCHIVE=%s\n' "$ARCHIVE"
printf 'ARCHIVE_SIZE=%s\n' "$archive_size"
printf 'ARCHIVE_SHA256=%s\n' "$archive_sha"
printf 'REMOVED_COUNT=%s\n' "$removed_count"
printf 'REMOVED_BYTES=%s\n' "$removed_bytes"
printf 'OLD_REMAINING=0\n'
printf 'CURRENT_CONFIG_ARCHIVES=1\n'
printf 'MANIFEST_VERIFY_OK=1\n'
printf 'HISTORICAL_FILES_IN_ARCHIVE=0\n'
printf 'SERVICES_UNCHANGED=1\n'
