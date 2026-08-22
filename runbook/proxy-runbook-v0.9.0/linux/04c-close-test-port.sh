#!/usr/bin/env bash
set -euo pipefail

PORT="${1:-24443}"

if [ "$(id -u)" -ne 0 ]; then
  echo "Run as root."
  exit 1
fi

echo "Current UFW rules containing $PORT:"
ufw status numbered | grep -F "$PORT" || {
  echo "No UFW rule containing $PORT. Nothing to do."
  exit 0
}

echo
echo "This test port is temporary. The script will remove EVERY UFW rule containing port $PORT."
read -r -p "Type CLOSE-$PORT to continue: " CONFIRM
if [ "$CONFIRM" != "CLOSE-$PORT" ]; then
  echo "Cancelled."
  exit 1
fi

# Delete matching numbered rules from bottom to top so indices do not shift.
mapfile -t NUMS < <(ufw status numbered | awk -v p="$PORT" '$0 ~ p {gsub(/[][]/,"",$1); print $1}' | sort -rn)
for n in "${NUMS[@]}"; do
  [ -n "$n" ] || continue
  yes | ufw delete "$n"
done

echo
ufw status numbered
echo "TEST_PORT_CLOSED_OK"
