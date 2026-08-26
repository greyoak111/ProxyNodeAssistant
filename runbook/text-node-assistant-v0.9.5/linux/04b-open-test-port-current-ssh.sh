#!/usr/bin/env bash
set -euo pipefail

PORT="${1:-24443}"

if [ "$(id -u)" -ne 0 ]; then
  echo "Run as root."
  exit 1
fi

if ! command -v ufw >/dev/null 2>&1; then
  echo "ERROR: ufw is not installed."
  exit 1
fi

CLIENT_IP="${SSH_CONNECTION%% *}"
if [ -z "${CLIENT_IP:-}" ] || [ "$CLIENT_IP" = "$SSH_CONNECTION" ]; then
  echo "ERROR: cannot detect SSH client IP from SSH_CONNECTION."
  echo "Do not guess. Run: echo \$SSH_CONNECTION"
  exit 1
fi

echo "Detected current SSH source IP: $CLIENT_IP"
echo "Will temporarily allow ONLY this source -> TCP $PORT."
read -r -p "Press Enter to continue, or type NO to cancel: " ANS
if [ "${ANS^^}" = "NO" ]; then
  echo "Cancelled."
  exit 0
fi

ufw allow from "$CLIENT_IP" to any port "$PORT" proto tcp comment 'text-node-assistant-reality-test'
ufw status numbered
echo
echo "TEST_PORT_OPEN_OK source=$CLIENT_IP port=$PORT"
echo "After 443 is verified, close this temporary rule with:"
echo "  bash /opt/text-node-assistant-current/linux/04c-close-test-port.sh"
