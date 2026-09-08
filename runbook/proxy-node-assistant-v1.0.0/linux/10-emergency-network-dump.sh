#!/usr/bin/env bash
set -u
umask 077
STAMP="$(date +%Y%m%d-%H%M%S)"
OUT="/root/emergency-network-${STAMP}.txt"

{
  echo "===== TIME ====="; date -Is 2>/dev/null || date
  echo "===== OS ====="; cat /etc/os-release 2>/dev/null || true
  echo "===== IP ====="; ip addr
  echo "===== ROUTE ALL ====="; ip route show table all
  echo "===== RULE ====="; ip rule
  echo "===== LISTENERS ====="; ss -lntup
  echo "===== UFW ====="; ufw status numbered
  echo "===== IPTABLES-SAVE ====="; iptables-save
  echo "===== IP6TABLES-SAVE ====="; ip6tables-save
  echo "===== NFT ====="; nft list ruleset 2>/dev/null || true
  echo "===== SYSCTL RP FILTER ====="
  sysctl net.ipv4.conf.all.rp_filter 2>/dev/null || true
  sysctl net.ipv4.conf.default.rp_filter 2>/dev/null || true
  echo "===== SERVICES ====="
  systemctl status ssh --no-pager || true
  systemctl status x-ui --no-pager || true
  systemctl status nginx --no-pager || true
  systemctl status warp-svc --no-pager || true
  echo "===== XUI JOURNAL ====="; journalctl -u x-ui -n 200 --no-pager || true
  echo "===== SSH JOURNAL ====="; journalctl -u ssh -n 200 --no-pager || true
  echo "===== NGINX JOURNAL ====="; journalctl -u nginx -n 120 --no-pager || true
  echo "===== WARP JOURNAL ====="; journalctl -u warp-svc -n 120 --no-pager || true
} > "$OUT" 2>&1

chmod 600 "$OUT"
echo "$OUT"
echo "This file may contain IPs and operational metadata. Review before sharing."
