#!/usr/bin/env bash
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
  echo "Run as root."
  exit 1
fi

read -r -p "SSH port currently used by this VPS [default 22]: " SSH_PORT
SSH_PORT="${SSH_PORT:-22}"
[[ "$SSH_PORT" =~ ^[0-9]+$ ]] && [ "$SSH_PORT" -ge 1 ] && [ "$SSH_PORT" -le 65535 ] || { echo "Invalid SSH port."; exit 1; }

if [ -n "${SSH_CONNECTION:-}" ]; then
  echo "Current SSH session detected: $SSH_CONNECTION"
else
  echo "WARNING: SSH_CONNECTION is empty. You may be in VNC/console or another shell."
fi

echo
cat <<TXT
This will ensure UFW allows:
  TCP ${SSH_PORT}  (SSH rescue/admin)
  TCP 80           (Let's Encrypt HTTP challenge / cover HTTP)
  TCP 443          (production REALITY)
It will NOT open:
  8443             (must stay localhost-only)
  <panel port>      (discovered per node; must stay localhost-only)
  40000            (WARP proxy must stay localhost-only)
  24443            (temporary test port is opened separately, preferably source-IP limited)
TXT

read -r -p "Type FIREWALL to continue: " ans
[ "$ans" = "FIREWALL" ] || { echo "Cancelled."; exit 1; }

ufw allow "${SSH_PORT}/tcp"
ufw allow 80/tcp
ufw allow 443/tcp

ufw --force enable

echo
ufw status numbered

echo
if ss -lntp | grep -E '0\.0\.0\.0:8443|\[::\]:8443' >/dev/null; then
  echo "ERROR: something is publicly listening on 8443. UFW may still block it, but this runbook requires localhost-only binding."
  exit 1
fi

echo "FIREWALL_BASELINE_OK"
echo "KEEP THIS SSH WINDOW OPEN until a second Windows terminal confirms SSH is still reachable."
