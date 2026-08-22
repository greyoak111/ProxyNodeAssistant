#!/usr/bin/env bash
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
  echo "Run as root."
  exit 1
fi

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y \
  curl wget ca-certificates gnupg lsb-release jq openssl \
  ufw tcpdump nginx certbot python3-certbot-nginx \
  fail2ban zip unzip

systemctl enable --now nginx
systemctl enable --now fail2ban

echo
echo "===== VERIFY ====="
for c in curl jq openssl ufw tcpdump nginx certbot fail2ban-client; do
  command -v "$c" || { echo "MISSING: $c"; exit 1; }
done
systemctl is-active nginx
systemctl is-active fail2ban
echo "BASE_INSTALL_OK"
