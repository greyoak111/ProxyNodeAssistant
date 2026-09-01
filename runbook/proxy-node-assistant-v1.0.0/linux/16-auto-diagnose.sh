#!/usr/bin/env bash
set -Eeuo pipefail

MODE="${1:-human}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PUB="/etc/proxy-runbook/public.env"
[ -f "$PUB" ] && . "$PUB"

add_issue() {
  local code="$1" severity="$2" zh="$3" en="$4" action="${5:-NONE}" auto="${6:-false}"
  ISSUES+=("${code}"$'\t'"${severity}"$'\t'"${action}"$'\t'"${auto}"$'\t'"${zh}"$'\t'"${en}")
}
pass() {
  local code="$1" zh="$2" en="$3"
  PASSES+=("${code}"$'\t'"${zh}"$'\t'"${en}")
}

ISSUES=()
PASSES=()

PUBLIC_NOW="$(curl -4fsS --max-time 8 https://api.ipify.org 2>/dev/null || true)"
if [ -z "${PUBLIC_IP:-}" ]; then
  add_issue PUBLIC_METADATA_MISSING INFO "尚未写入公网 IP 运行态；实时探测不受影响" \
    "Stored public-IP metadata is absent; live probing still works" RECONVERGE false
elif [ "$PUBLIC_NOW" = "$PUBLIC_IP" ]; then
  pass PUBLIC_IP "公网 IPv4 与运行态记录一致" "Public IPv4 matches runtime metadata"
else
  add_issue PUBLIC_IP_MISMATCH WARN "公网 IPv4 与运行态记录不一致；如果刚换 IP，需要重新收敛 DNS/客户端配置" \
    "Public IPv4 differs from runtime metadata; after an IP change, reconverge DNS/client settings" RECONVERGE false
fi

if systemctl is-active --quiet x-ui 2>/dev/null; then
  pass XUI_ACTIVE "3x-ui/x-ui 正在运行" "3x-ui/x-ui is running"
else
  add_issue XUI_DOWN ERROR "x-ui 未运行；代理 443 可能因此不可用" "x-ui is not running; proxy 443 may be unavailable" START_XUI true
fi

if systemctl is-active --quiet nginx 2>/dev/null; then
  pass NGINX_ACTIVE "Nginx 正在运行" "Nginx is running"
else
  add_issue NGINX_DOWN ERROR "Nginx 未运行；网站伪装/REALITY 本地回落会失败" \
    "Nginx is not running; cover site/REALITY local fallback will fail" START_NGINX true
fi

if systemctl is-active --quiet fail2ban 2>/dev/null; then
  pass FAIL2BAN "fail2ban 正常" "fail2ban is active"
else
  add_issue FAIL2BAN_DOWN WARN "fail2ban 未运行" "fail2ban is not active" START_FAIL2BAN true
fi

if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep 'Status: active' >/dev/null; then
  pass UFW "UFW 已启用" "UFW is active"
else
  add_issue UFW_OFF WARN "UFW 未启用；修复前会先保留 SSH/80/443" "UFW is inactive; repair will allow SSH/80/443 before enabling it" ENABLE_UFW true
fi

if ss -lntp 2>/dev/null | grep -E ':443[[:space:]]' >/dev/null; then
  pass PORT443 "TCP 443 有监听" "TCP 443 has a listener"
else
  add_issue PORT443_MISSING ERROR "TCP 443 没有监听；正式代理入口不可用" "TCP 443 has no listener; production proxy entry is unavailable" CHECK_XRAY false
fi

if [ -x "$ROOT/linux/23-ss2022-tcp.sh" ]; then
  SS_STATUS="$(bash "$ROOT/linux/23-ss2022-tcp.sh" status 2>/dev/null || true)"
  SS_PRESENT="$(awk -F= '$1=="PRESENT"{print $2}' <<<"$SS_STATUS" | sed -n '1p')"
  SS_ACTIVE="$(awk -F= '$1=="ACTIVE"{print $2}' <<<"$SS_STATUS" | sed -n '1p')"
  SS_LISTENER="$(awk -F= '$1=="LISTENER"{print $2}' <<<"$SS_STATUS" | sed -n '1p')"
  SS_FIREWALL="$(awk -F= '$1=="FIREWALL"{print $2}' <<<"$SS_STATUS" | sed -n '1p')"
  SS_ALLOWED="$(awk -F= '$1=="ALLOWLIST_COUNT"{print $2}' <<<"$SS_STATUS" | sed -n '1p')"
  if [ "$SS_PRESENT/$SS_ACTIVE/$SS_LISTENER/$SS_FIREWALL" = "1/1/1/1" ]; then
    pass SS2022_SERVICE "SS2022 TCP-only 服务、监听和来源白名单防火墙均正常" \
      "SS2022 TCP-only service, listener, and source allowlist firewall are healthy"
  else
    add_issue SS2022_SERVICE_BAD ERROR "SS2022 服务/监听/来源防火墙不完整" \
      "SS2022 service/listener/source firewall is incomplete" REPAIR_SS2022 true
  fi
  if [ "${SS_ALLOWED:-0}" -gt 0 ] 2>/dev/null; then
    pass SS2022_ALLOWLIST "SS2022 已配置 ${SS_ALLOWED} 个精确 IPv4 来源" \
      "SS2022 has ${SS_ALLOWED} exact IPv4 source entries"
  else
    add_issue SS2022_ALLOWLIST_EMPTY WARN "SS2022 尚无允许来源；请在客户端菜单中检测当前公网 IP 后明确添加" \
      "SS2022 has no allowed source; explicitly detect and add the current public IP from the client menu" ADD_SS2022_SOURCE false
  fi
else
  add_issue SS2022_MODULE_MISSING ERROR "SS2022 管理模块缺失；需要升级工具包" \
    "The SS2022 management module is missing; upgrade the toolkit" RECONVERGE false
fi

L8443="$(ss -lntp 2>/dev/null | grep -E ':8443[[:space:]]' || true)"
if echo "$L8443" | grep -q '127.0.0.1:8443' && ! echo "$L8443" | grep -qE '0\.0\.0\.0:8443|\[::\]:8443'; then
  pass PORT8443 "8443 只监听 127.0.0.1，符合预期" "8443 is bound only to 127.0.0.1"
else
  add_issue PORT8443_BAD ERROR "8443 缺失或不是 localhost-only；REALITY 回落/伪装后端不安全或不可用" \
    "8443 is missing or not localhost-only; REALITY fallback is broken or exposed" REBUILD_COVER false
fi

if [ -z "${PANEL_PORT:-}" ] && [ -x "$ROOT/linux/18-panel-metadata.sh" ]; then
  PANEL_META="$(bash "$ROOT/linux/18-panel-metadata.sh" 2>/dev/null || true)"
  PANEL_PORT="$(awk -F= '$1=="PANEL_PORT" && !found {print $2; found=1}' <<<"$PANEL_META")"
  WEB_BASE_PATH="$(awk -F= '$1=="WEB_BASE_PATH" && !found {print substr($0,index($0,"=")+1); found=1}' <<<"$PANEL_META")"
fi

if [ -n "${PANEL_PORT:-}" ]; then
  LP="$(ss -lntp 2>/dev/null | grep -E ":${PANEL_PORT}[[:space:]]" || true)"
  if echo "$LP" | grep -q "127.0.0.1:${PANEL_PORT}" && ! echo "$LP" | grep -qE "0\.0\.0\.0:${PANEL_PORT}|\[::\]:${PANEL_PORT}"; then
    pass PANEL_LOCAL "3x-ui 面板仅 localhost 监听" "3x-ui panel is localhost-only"
  else
    add_issue PANEL_EXPOSED ERROR "3x-ui 面板未正确限制在 localhost" "3x-ui panel is not correctly restricted to localhost" LOCK_PANEL true
  fi
else
  add_issue PANEL_METADATA WARN "没有 panel 运行态元数据；先运行自适应收敛" "Panel runtime metadata is missing; run adaptive convergence" RECONVERGE false
fi

REALITY_OBJ=""
SUB_ID=""
if [ -r "$ROOT/linux/lib-xui-api.sh" ]; then
  # shellcheck source=lib-xui-api.sh
  . "$ROOT/linux/lib-xui-api.sh"
  if xui_api_context >/dev/null 2>&1; then
    REALITY_OBJ="$(xui_api_get "/panel/api/inbounds/list" 2>/dev/null | \
      jq -c '.obj[]? | select(.port==443 and .protocol=="vless" and .streamSettings.security=="reality")' 2>/dev/null | sed -n '1p')"
    if [ -n "$REALITY_OBJ" ]; then
      SHARE_STRATEGY="$(jq -r '.shareAddrStrategy // empty' <<<"$REALITY_OBJ")"
      SHARE_ADDRESS="$(jq -r '.shareAddr // empty' <<<"$REALITY_OBJ")"
      SUB_ID="$(jq -r '.settings.clients[]? | select((.enable // true)==true) | .subId // empty' <<<"$REALITY_OBJ" | sed -n '1p')"
      if [ "$SHARE_STRATEGY" = "custom" ] && [ -n "$PUBLIC_NOW" ] && [ "$SHARE_ADDRESS" = "$PUBLIC_NOW" ]; then
        pass REALITY_SHARE_ADDRESS "订阅生成的节点地址是当前 VPS 公网地址" "Subscription output uses the current VPS public address"
      else
        add_issue REALITY_SHARE_ADDRESS_BAD ERROR "3x-ui 订阅会生成错误节点地址（常见为 localhost），客户端测速会显示 -1" \
          "3x-ui subscription output uses the wrong node address (often localhost), causing client latency -1" NORMALIZE_SUBSCRIPTION true
      fi
    fi
  fi
fi

if [ -n "${COVER_DOMAIN:-}" ]; then
  DNS="$(getent ahostsv4 "$COVER_DOMAIN" 2>/dev/null | awk '{print $1}' | sort -u | tr '\n' ' ')"
  if [ -n "$PUBLIC_NOW" ] && echo " $DNS " | grep -q " $PUBLIC_NOW "; then
    pass DNS "Cover 域名 DNS 指向当前 VPS" "Cover-domain DNS points to this VPS"
  else
    add_issue DNS_MISMATCH ERROR "Cover 域名没有解析到当前 VPS；需要人工修 DNS" \
      "Cover domain does not resolve to this VPS; DNS requires user action" FIX_DNS false
  fi

  HTTP_CODE="$(curl --noproxy '*' --silent --output /dev/null --max-time 15 --write-out '%{http_code}' \
    "http://${COVER_DOMAIN}/" 2>/dev/null || true)"
  case "$HTTP_CODE" in
    200|204|301|302|304) pass COVER_HTTP_PUBLIC "伪装站可从公网通过 HTTP 访问" "The cover site is publicly reachable over HTTP" ;;
    403) add_issue COVER_HTTP_FORBIDDEN ERROR "公网访问伪装站返回 403；ACME 验证也会失败，检查 Nginx allow/deny、认证和重复 server 块" \
      "Public cover access returns 403; ACME will also fail. Check Nginx allow/deny, authentication, and duplicate server blocks" REBUILD_COVER false ;;
    *) add_issue COVER_HTTP_BAD WARN "公网 HTTP 检查失败或返回异常状态 ${HTTP_CODE:-NONE}" \
      "Public HTTP check failed or returned unexpected status ${HTTP_CODE:-NONE}" REBUILD_COVER false ;;
  esac

  CERT="/etc/letsencrypt/live/${COVER_DOMAIN}/fullchain.pem"
  if [ -s "$CERT" ]; then
    if openssl x509 -checkend $((14*86400)) -noout -in "$CERT" >/dev/null 2>&1; then
      pass CERT "TLS 证书至少还有 14 天有效期" "TLS certificate is valid for at least 14 more days"
    else
      add_issue CERT_EXPIRING WARN "TLS 证书将在 14 天内过期或已过期" "TLS certificate expires within 14 days or is expired" RENEW_CERT true
    fi
  else
    add_issue CERT_MISSING ERROR "Cover TLS 证书缺失" "Cover TLS certificate is missing" REBUILD_COVER false
  fi

  SUB_LISTEN="$(ss -lntp 2>/dev/null | grep -E ':2096[[:space:]]' || true)"
  if grep -q '127.0.0.1:2096' <<<"$SUB_LISTEN" && \
     ! grep -Eq '0\.0\.0\.0:2096|\[::\]:2096|\*:2096' <<<"$SUB_LISTEN"; then
    pass SUBSCRIPTION_LOCAL "3x-ui 订阅服务仅监听 localhost:2096" "3x-ui subscription service is localhost-only on port 2096"
  else
    add_issue SUBSCRIPTION_LISTEN_BAD ERROR "3x-ui 订阅服务缺失或不是 localhost-only" \
      "3x-ui subscription service is missing or not localhost-only" NORMALIZE_SUBSCRIPTION true
  fi

  if nginx -T 2>/dev/null | grep -F 'proxy_pass http://127.0.0.1:2096;' >/dev/null; then
    pass SUBSCRIPTION_PROXY "HTTPS 伪装站已安全反代订阅路径" "The HTTPS cover site safely proxies the subscription path"
  else
    add_issue SUBSCRIPTION_PROXY_MISSING WARN "HTTPS 订阅反代缺失；面板复制的订阅地址可能不可访问" \
      "The HTTPS subscription reverse proxy is missing; panel-generated subscription URLs may be unreachable" NORMALIZE_SUBSCRIPTION true
  fi

  if [ -n "$SUB_ID" ] && [ -n "$REALITY_OBJ" ]; then
    SUB_BODY="$(curl -fsS --max-time 15 "https://${COVER_DOMAIN}/sub/${SUB_ID}" 2>/dev/null || true)"
    SUB_LINK="$(printf '%s' "$SUB_BODY" | base64 -d 2>/dev/null | sed -n '1p')"
    SUB_HOST="${SUB_LINK#*@}"
    SUB_HOST="${SUB_HOST%%:*}"
    if [[ "$SUB_LINK" == vless://* ]] && [ -n "$PUBLIC_NOW" ] && [ "$SUB_HOST" = "$PUBLIC_NOW" ]; then
      pass SUBSCRIPTION_PUBLIC "公网 HTTPS 订阅可下载，且解码后的节点地址正确" "The public HTTPS subscription downloads and decodes to the correct node address"
    else
      add_issue SUBSCRIPTION_PUBLIC_BAD ERROR "公网订阅不可用或仍生成错误节点地址；客户端会显示 -1" \
        "The public subscription is unavailable or still emits the wrong node address, causing client latency -1" NORMALIZE_SUBSCRIPTION true
    fi
  fi

  if [ -f /var/www/cover/.proxy-runbook-cover ]; then
    pass COVER_POLISHED "前台伪装已是 runbook 管理的完整静态站" "Cover frontend is the managed polished static site"
  elif [ -f /var/www/cover/index.html ] && grep -qE 'This site is online|<h1>Welcome</h1>' /var/www/cover/index.html; then
    add_issue COVER_PLACEHOLDER WARN "前台还是简陋占位页，可安全升级为完整静态伪装站" \
      "Cover is still a minimal placeholder and can be safely upgraded" POLISH_COVER true
  elif [ -f /var/www/cover/index.html ]; then
    add_issue COVER_CUSTOM INFO "检测到自定义前台；不会自动覆盖" "A custom cover site was detected; it will not be overwritten automatically" KEEP_CUSTOM_COVER false
  else
    add_issue COVER_MISSING ERROR "没有前台网站文件" "Cover-site files are missing" REBUILD_COVER false
  fi
fi

if systemctl is-active --quiet warp-svc 2>/dev/null; then
  TRACE="$(curl -fsS --max-time 20 --proxy socks5h://127.0.0.1:40000 https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null || true)"
  if ss -lntp 2>/dev/null | grep '127.0.0.1:40000' >/dev/null && echo "$TRACE" | grep -q '^warp=on'; then
    pass WARP "WARP MASQUE Local Proxy 正常" "WARP MASQUE Local Proxy is healthy"
  else
    add_issue WARP_BAD WARN "warp-svc 在运行，但 localhost:40000/MASQUE 出口未通过验证" \
      "warp-svc runs, but localhost:40000/MASQUE egress failed verification" RECONNECT_WARP true
  fi
else
  add_issue WARP_DOWN WARN "WARP 未运行；OpenAI 特殊出口可能不可用" "WARP is not running; special OpenAI egress may be unavailable" START_WARP true
fi

if [ -s /root/.config/proxy-runbook/performance-profile.env ]; then
  PROFILE="$(sed -n 's/^PROFILE=//p' /root/.config/proxy-runbook/performance-profile.env | sed -n '1p')"
  pass PERFORMANCE_PROFILE "已应用可回滚性能档位：${PROFILE:-unknown}" "A rollback-capable performance profile is active: ${PROFILE:-unknown}"
else
  add_issue PERFORMANCE_UNMANAGED INFO "尚未应用 v0.9.5 可回滚性能档位；可在菜单 [16] 检测后选择" \
    "No v0.9.5 rollback-capable profile is applied; inspect and choose one from menu [16]" PERFORMANCE_PROFILE false
fi

if command -v vnstat >/dev/null 2>&1; then
  pass VNSTAT "vnStat 已安装；菜单 [17] 可按额度和重置日估算当期流量" \
    "vnStat is installed; menu [17] can estimate period usage using the configured quota and reset day"
else
  add_issue VNSTAT_MISSING INFO "尚未安装 vnStat；菜单 [17] 可经确认后安装" \
    "vnStat is not installed; menu [17] can install it after confirmation" INSTALL_VNSTAT false
fi

DISK="$(df -P / | awk 'NR==2{gsub(/%/,"",$5); print $5}')"
if [ "${DISK:-0}" -lt 85 ]; then
  pass DISK "根分区空间正常（${DISK}% 已用）" "Root filesystem usage is healthy (${DISK}% used)"
else
  add_issue DISK_HIGH WARN "根分区已使用 ${DISK}%，需要人工清理" "Root filesystem is ${DISK}% used and needs manual cleanup" CLEAN_DISK false
fi

# DOCKER-USER is a classic source of 'UFW says ALLOW but still unreachable'.
if command -v iptables >/dev/null 2>&1 && iptables -S DOCKER-USER >/dev/null 2>&1; then
  DROPS="$(iptables -S DOCKER-USER 2>/dev/null | grep -- '-j DROP' || true)"
  if [ -n "$DROPS" ]; then
    add_issue DOCKER_USER_DROP INFO "DOCKER-USER 存在 DROP 规则；若 Docker 服务公网不通，优先核对这里，不自动删除" \
      "DOCKER-USER contains DROP rules; if a Docker service is unreachable, inspect them first. They are never auto-deleted" INSPECT_DOCKER_USER false
  else
    pass DOCKER_USER "DOCKER-USER 未发现显式 DROP" "No explicit DROP rule found in DOCKER-USER"
  fi
fi

if [ "$MODE" = "--protocol-v1" ] || [ "$MODE" = "protocol-v1" ]; then
  echo "__PNA_DIAG_V1_BEGIN__"
  for record in "${PASSES[@]}"; do
    printf 'PASS\t%s\n' "$record"
  done
  for record in "${ISSUES[@]}"; do
    printf 'ISSUE\t%s\n' "$record"
  done
  echo "__PNA_DIAG_V1_END__"
  exit 0
fi

echo "===== AUTO DIAGNOSIS ====="
echo
for record in "${PASSES[@]}"; do
  IFS=$'\t' read -r code zh en <<<"$record"
  printf '[GOOD] %s: %s / %s\n' "$code" "$zh" "$en"
done
echo
NEEDS_ACTION=0
for record in "${ISSUES[@]}"; do
  IFS=$'\t' read -r code severity action auto zh en <<<"$record"
  printf '[%s] %s: %s / %s\n  NEXT=%s AUTO_REPAIR=%s\n' "$severity" "$code" "$zh" "$en" "$action" "$auto"
  [ "$severity" = "ERROR" ] && NEEDS_ACTION=1
done
echo
if [ "$NEEDS_ACTION" -eq 0 ]; then
  echo "DIAGNOSIS_GOOD"
else
  echo "DIAGNOSIS_NEEDS_ACTION"
fi
