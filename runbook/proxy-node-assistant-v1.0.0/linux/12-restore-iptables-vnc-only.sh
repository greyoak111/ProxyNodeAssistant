#!/usr/bin/env bash
set -euo pipefail

echo "DANGER: use from provider VNC/console, not from your only SSH session."
read -r -p "Path to saved iptables.rules: " RULES
[ -f "$RULES" ] || { echo "File not found."; exit 1; }

echo "Current rules are being backed up first."
NOW="/root/iptables-before-restore-$(date +%Y%m%d-%H%M%S).rules"
iptables-save > "$NOW"
echo "Saved current rules to $NOW"

read -r -p "Type RESTORE to apply $RULES: " ans
[ "$ans" = "RESTORE" ] || { echo "Cancelled."; exit 1; }

iptables-restore < "$RULES"
echo "RESTORE_DONE"
iptables -L -n -v --line-numbers
