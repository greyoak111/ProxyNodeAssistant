#!/usr/bin/env bash
set -euo pipefail
umask 077

STAMP="$(date +%Y%m%d-%H%M%S)"
DIR="/root/proxy-node-backup-${STAMP}"
TGZ="${DIR}.tar.gz"

cleanup_expanded_backup() {
  rm -rf -- "$DIR"
}
trap cleanup_expanded_backup EXIT

mkdir -p "$DIR/files" "$DIR/state"

copy_if_exists() {
  local src="$1"
  if [ -e "$src" ]; then
    cp -a "$src" "$DIR/files/" || true
  fi
}

copy_path_if_exists() {
  local src="$1"
  if [ -e "$src" ] || [ -L "$src" ]; then
    (cd / && cp -a --parents "${src#/}" "$DIR/files/") || true
  fi
}

copy_if_exists /etc/x-ui
copy_if_exists /usr/local/x-ui
copy_if_exists /etc/nginx
copy_if_exists /etc/letsencrypt
copy_if_exists /etc/ufw
copy_if_exists /etc/fail2ban
copy_if_exists /etc/network/interfaces
copy_if_exists /etc/netplan
copy_if_exists /etc/sysctl.conf
copy_if_exists /etc/sysctl.d
copy_if_exists /etc/apt/sources.list.d/cloudflare-client.list

# WARP state can contain device identity; keep it only inside this root-only backup.
copy_if_exists /var/lib/cloudflare-warp
copy_if_exists /etc/proxy-runbook
copy_if_exists /root/.config/proxy-runbook
copy_if_exists /var/www/cover
copy_path_if_exists /etc/proxy-node-assistant
copy_path_if_exists /opt/proxy-node-assistant/copyparty
copy_path_if_exists /srv/proxy-node-assistant/drive-data
copy_path_if_exists /var/lib/proxy-node-assistant/copyparty
copy_path_if_exists /var/log/proxy-node-assistant/copyparty
copy_path_if_exists /etc/systemd/system/proxy-node-assistant-copyparty.service
copy_path_if_exists /usr/local/lib/proxy-node-assistant/security-firewall.sh
copy_path_if_exists /etc/systemd/system/proxy-node-assistant-security-firewall.service
copy_path_if_exists /etc/logrotate.d/proxy-node-assistant-security
copy_if_exists /etc/systemd/system/x-ui.service
copy_if_exists /etc/systemd/system/x-ui.service.d
copy_if_exists /etc/systemd/system/nginx.service.d
copy_if_exists /etc/systemd/system/proxy-runbook-zram.service

ip -br addr > "$DIR/state/ip-addr.txt" 2>&1 || true
ip route show table all > "$DIR/state/ip-route-all.txt" 2>&1 || true
ss -lntup > "$DIR/state/listeners.txt" 2>&1 || true
ufw status numbered > "$DIR/state/ufw.txt" 2>&1 || true
iptables-save > "$DIR/state/iptables.rules" 2>&1 || true
ip6tables-save > "$DIR/state/ip6tables.rules" 2>&1 || true
nft list ruleset > "$DIR/state/nft-ruleset.txt" 2>&1 || true
systemctl status x-ui --no-pager > "$DIR/state/x-ui-status.txt" 2>&1 || true
systemctl status nginx --no-pager > "$DIR/state/nginx-status.txt" 2>&1 || true
systemctl status warp-svc --no-pager > "$DIR/state/warp-status.txt" 2>&1 || true
systemctl status ssh --no-pager > "$DIR/state/ssh-status.txt" 2>&1 || true
systemctl status proxy-node-assistant-copyparty --no-pager > "$DIR/state/copyparty-status.txt" 2>&1 || true
systemctl status proxy-node-assistant-security-firewall --no-pager > "$DIR/state/security-firewall-status.txt" 2>&1 || true
fail2ban-client status sshd > "$DIR/state/fail2ban-sshd-status.txt" 2>&1 || true
journalctl -u x-ui -n 200 --no-pager > "$DIR/state/x-ui-journal.txt" 2>&1 || true
journalctl -u nginx -n 200 --no-pager > "$DIR/state/nginx-journal.txt" 2>&1 || true
journalctl -u warp-svc -n 200 --no-pager > "$DIR/state/warp-journal.txt" 2>&1 || true
journalctl -u proxy-node-assistant-copyparty -n 200 --no-pager > "$DIR/state/copyparty-journal.txt" 2>&1 || true
# Raw IP-bearing security event logs are intentionally excluded from ordinary backups.
echo 'RAW_SECURITY_EVENT_LOGS_EXCLUDED=1' > "$DIR/state/security-log-privacy.txt"

if command -v warp-cli >/dev/null 2>&1; then
  warp-cli --version > "$DIR/state/warp-version.txt" 2>&1 || true
  warp-cli settings > "$DIR/state/warp-settings.txt" 2>&1 || true
  warp-cli status > "$DIR/state/warp-cli-status.txt" 2>&1 || true
fi

if [ -x /usr/local/x-ui/x-ui ]; then
  /usr/local/x-ui/x-ui version > "$DIR/state/x-ui-version.txt" 2>&1 || true
fi

dpkg-query -W -f='${Package}\t${Version}\t${db:Status-Abbrev}\n' \
  > "$DIR/state/dpkg-packages.tsv" 2>&1 || true
systemctl list-unit-files --no-pager > "$DIR/state/systemd-unit-files.txt" 2>&1 || true

tar -C /root -czf "$TGZ" "$(basename "$DIR")"
chmod 600 "$TGZ"
cleanup_expanded_backup
trap - EXIT

echo "BACKUP_OK"
echo "$TGZ"
echo
echo "Keep this file private: it may contain panel DB, certificates, and WARP device identity."
