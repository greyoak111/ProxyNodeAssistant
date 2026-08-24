#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

[ "$(id -u)" -eq 0 ] || { echo "Run as root."; exit 1; }

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/linux/lib-third-party.sh"

if [ -x /usr/local/x-ui/x-ui ]; then
  echo "3x-ui already exists. This script will NOT reinstall or upgrade it."
  exit 0
fi

echo "Official unattended stable install."
echo "Credentials and panel path are generated uniquely by 3x-ui."
read -r -p "Type INSTALL to continue: " ans
[ "$ans" = "INSTALL" ] || { echo "Cancelled."; exit 1; }

export XUI_NONINTERACTIVE=1
export XUI_SSL_MODE=none
export XUI_DB_TYPE=sqlite
pna_install_3xui_pinned "$ROOT"

echo
echo "===== REAL GENERATED 3X-UI CREDENTIALS ====="
cat /etc/x-ui/install-result.env
echo "============================================="
echo "The file above is mode 600 and stays on this VPS."
