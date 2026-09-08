#!/usr/bin/env bash
set -u

echo "===== 0. TIME ====="
date -Is 2>/dev/null || date
echo

echo "===== 1. OS ====="
cat /etc/os-release 2>/dev/null || true
echo

echo "===== 2. HOSTNAME ====="
hostnamectl 2>/dev/null || hostname
echo

echo "===== 3. CPU / MEMORY / DISK ====="
nproc 2>/dev/null || true
free -h 2>/dev/null || true
df -hT / 2>/dev/null || true
echo

echo "===== 4. ADDRESSES ====="
ip -br addr 2>/dev/null || ip addr
echo

echo "===== 5. ROUTES ====="
ip route
echo

echo "===== 6. PUBLIC IPv4 (best effort) ====="
if command -v curl >/dev/null 2>&1; then
  curl -4fsS --max-time 8 https://api.ipify.org || true
  echo
else
  echo "curl not installed yet"
fi
echo

echo "===== 7. LISTENERS ====="
ss -lntup 2>/dev/null || ss -lntp 2>/dev/null || true
echo

echo "===== 8. IMPORTANT PORTS ====="
for p in 22 80 443 8443 24443 40000; do
  echo "--- port $p ---"
  ss -lntp 2>/dev/null | grep -E ":${p}[[:space:]]" || echo "(no TCP listener)"
done
echo

echo "===== 9. FIREWALL ====="
if command -v ufw >/dev/null 2>&1; then
  ufw status numbered || true
else
  echo "ufw not installed"
fi
echo

echo "===== 10. SERVICES ====="
for s in ssh x-ui nginx warp-svc fail2ban; do
  printf "%-12s " "$s"
  systemctl is-active "$s" 2>/dev/null || echo "not-installed/inactive"
done
echo

echo "===== 11. DOCKER ====="
if command -v docker >/dev/null 2>&1; then
  docker ps --format 'table {{.Names}}\t{{.Image}}\t{{.Ports}}' || true
else
  echo "docker not installed"
fi
echo

echo "===== RESULT ====="
echo "This script made no configuration changes."
echo "STOP if :443 is already occupied by an unknown service."
