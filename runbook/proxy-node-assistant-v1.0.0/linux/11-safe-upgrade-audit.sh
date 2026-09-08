#!/usr/bin/env bash
set -euo pipefail

echo "This script does NOT upgrade packages."
echo "It only refreshes package metadata and prints what would change."
echo

apt-get update
echo
echo "===== UPGRADABLE ====="
apt list --upgradable 2>/dev/null || true

echo
echo "===== IMPORTANT INSTALLED VERSIONS ====="
dpkg-query -W -f='${Package}\t${Version}\n' nginx certbot cloudflare-warp 2>/dev/null || true
if [ -x /usr/local/x-ui/x-ui ]; then
  /usr/local/x-ui/x-ui version || true
fi
warp-cli --version 2>/dev/null || true
nginx -v 2>&1 || true
certbot --version 2>&1 || true

echo
echo "Before any real upgrade, run 01-safe-backup.sh and keep a working SSH/VNC rescue path."
