#!/usr/bin/env bash
set -u

section(){ echo; echo "===== $* ====="; }

section TIME
date -Is 2>/dev/null || date

section UPTIME
uptime || true

section IP
ip -br addr || true

section ROUTE
ip route || true

section PUBLIC_IP_DIRECT
curl -4fsS --max-time 8 https://api.ipify.org || true
echo

section LISTENERS
ss -lntup || true

section X_UI
systemctl status x-ui --no-pager || true

section NGINX
systemctl status nginx --no-pager || true
nginx -t 2>&1 || true

section WARP
systemctl status warp-svc --no-pager || true
warp-cli status 2>/dev/null || true
warp-cli settings 2>/dev/null || true

section UFW
ufw status numbered || true

section IPTABLES_INPUT
iptables -L INPUT -n -v --line-numbers || true

section IPTABLES_FORWARD
iptables -L FORWARD -n -v --line-numbers || true

section DOCKER_USER
iptables -L DOCKER-USER -n -v --line-numbers 2>/dev/null || true

section DISK
df -hT || true

section MEMORY
free -h || true

section PERFORMANCE_PROFILE
if [ -x /opt/text-node-assistant-current/linux/20-adaptive-performance.sh ]; then
  bash /opt/text-node-assistant-current/linux/20-adaptive-performance.sh --status || true
else
  echo "PERFORMANCE_PROFILE_UNAVAILABLE"
fi

section TRAFFIC_COUNTER
if [ -x /opt/text-node-assistant-current/linux/21-traffic-status.sh ]; then
  bash /opt/text-node-assistant-current/linux/21-traffic-status.sh --status || true
else
  echo "TRAFFIC_COUNTER_UNAVAILABLE"
fi

section IP_REBIND_TRANSACTION
if [ -x /opt/text-node-assistant-current/linux/27-ip-rebind.sh ]; then
  bash /opt/text-node-assistant-current/linux/27-ip-rebind.sh status || true
else
  echo "IP_REBIND_STATUS_UNAVAILABLE"
fi

section CERTS
certbot certificates 2>/dev/null || true

section LAST_XUI_LOG
journalctl -u x-ui -n 80 --no-pager || true

section LAST_NGINX_LOG
journalctl -u nginx -n 50 --no-pager || true

echo
echo "STATUS_DONE"
