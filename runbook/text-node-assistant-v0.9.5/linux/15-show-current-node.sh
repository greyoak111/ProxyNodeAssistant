#!/usr/bin/env bash
set -u
PUB="/etc/proxy-runbook/public.env"

echo "===== CURRENT RUNTIME NODE METADATA ====="
if [ -f "$PUB" ]; then
  cat "$PUB"
else
  echo "No runtime metadata yet."
  echo "The shared toolkit intentionally has no baked-in node values."
fi
echo
echo "Detected public IP now:"
curl -4fsS --max-time 8 https://api.ipify.org 2>/dev/null || true
echo
