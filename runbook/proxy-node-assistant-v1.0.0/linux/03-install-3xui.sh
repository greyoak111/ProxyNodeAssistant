#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

[ "$(id -u)" -eq 0 ] || { echo "Run as root."; exit 1; }

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
bash <(curl -Ls https://raw.githubusercontent.com/MHSanaei/3x-ui/master/install.sh)

echo
echo "===== REAL GENERATED 3X-UI CREDENTIALS ====="
cat /etc/x-ui/install-result.env
echo "============================================="
echo "The file above is mode 600 and stays on this VPS."
