#!/usr/bin/env bash
set -Eeuo pipefail

[ "$(id -u)" -eq 0 ] || { echo "ERROR: run as root (or sudo)."; exit 1; }

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

echo "===== PROXY NODE ASSISTANT TOOLKIT BOOTSTRAP ====="
echo "Toolkit: $ROOT"

find "$ROOT/linux" -type f -name '*.sh' -exec sed -i 's/\r$//' {} +
chmod 700 "$ROOT"/linux/*.sh

ln -sfn "$ROOT" /opt/proxy-node-assistant-current
# Compatibility aliases let v0.9.0/v0.9.5 clients finish a controlled upgrade.
ln -sfn "$ROOT" /opt/text-node-assistant-current
ln -sfn "$ROOT" /opt/proxy-runbook-current

cat > /usr/local/sbin/proxy-node <<'EOF'
#!/usr/bin/env bash
if [ "$(id -u)" -ne 0 ]; then
  exec sudo /opt/proxy-node-assistant-current/linux/13-maintenance-menu.sh "$@"
else
  exec /opt/proxy-node-assistant-current/linux/13-maintenance-menu.sh "$@"
fi
EOF
chmod 755 /usr/local/sbin/proxy-node

cat > /usr/local/sbin/text-node <<'EOF'
#!/usr/bin/env bash
exec /usr/local/sbin/proxy-node "$@"
EOF
chmod 755 /usr/local/sbin/text-node

PUBLIC_NOW="$(curl -4fsS --max-time 8 https://api.ipify.org 2>/dev/null || true)"
echo "Detected public IPv4: ${PUBLIC_NOW:-UNKNOWN}"

echo
echo "===== PRODUCTION DETECTION ====="
if systemctl is-active --quiet x-ui 2>/dev/null || [ -x /usr/local/x-ui/x-ui ]; then
  echo "NODE_MODE_HINT=EXISTING"
  echo "Existing 3x-ui detected. Adaptive mode will back up first and will not reinstall it."
else
  echo "NODE_MODE_HINT=FRESH"
  echo "No 3x-ui detected. Adaptive mode may perform a fresh unattended install."
fi

echo
echo "===== READ-ONLY PREFLIGHT ====="
bash "$ROOT/linux/00-preflight-vps.sh"

echo
echo "BOOTSTRAP_OK"
echo "Maintenance command:"
echo "  proxy-node"
echo "Compatibility command:"
echo "  text-node"
