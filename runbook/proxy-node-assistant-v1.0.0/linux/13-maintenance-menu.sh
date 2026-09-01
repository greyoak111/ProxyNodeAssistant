#!/usr/bin/env bash
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

while true; do
  clear 2>/dev/null || true
  cat <<'EOF'
=========================================
 TEXT NODE - 维护菜单（只读优先）
=========================================
1) 一键体检（推荐）
2) 完整状态
3) 立刻做安全备份
4) 检查 WARP / MASQUE
5) Nginx + 证书检查
6) 看监听端口
7) 网络异常：生成急救报告
8) 升级前审计（不升级）
9) 当前节点真相
A) 自适应检查并优化（有备份/有确认）
C) 显示真实 Credential Handoff
P) 生成/轮换 VPS 登录密码并显示
X) 生成/轮换 3x-ui 用户名密码并显示
R) 导出当前 443 REALITY 真密钥/链接
D) 自动排障诊断（中英双语）
F) 安全自动修复（先备份）
W) 优化前台伪装 + Nginx 后端
V) 性能档位：检测 / 自动应用 / 回滚
T) 流量统计：vnStat 状态 / 安装 / JSON
0) 退出
EOF
  read -r -p "选择 [0-9/A/C/P/X/R/D/F/W/V/T]: " CHOICE
  case "$CHOICE" in
    1) bash "$ROOT/linux/14-node-doctor.sh" ;;
    2) bash "$ROOT/linux/09-status-node.sh" ;;
    3) bash "$ROOT/linux/01-safe-backup.sh" ;;
    4) bash "$ROOT/linux/08-warp-check.sh" ;;
    5)
       nginx -t 2>&1 || true
       echo
       certbot certificates 2>/dev/null || true
       ;;
    6) ss -lntup 2>/dev/null || ss -lntp ;;
    7) bash "$ROOT/linux/10-emergency-network-dump.sh" ;;
    8) bash "$ROOT/linux/11-safe-upgrade-audit.sh" ;;
    9) bash "$ROOT/linux/15-show-current-node.sh" ;;
    A|a) bash "$ROOT/linux/00-auto-install-or-optimize.sh" ;;
    C|c)
       . "$ROOT/linux/lib-handoff.sh"
       handoff_show
       ;;
    P|p)
       read -r -p "要轮换密码的 VPS 用户名: " U
       [ -n "$U" ] && bash "$ROOT/linux/01a-rotate-vps-password.sh" "$U"
       ;;
    X|x) bash "$ROOT/linux/03c-rotate-panel-credentials.sh" ;;
    R|r) bash "$ROOT/linux/04e-export-reality-handoff.sh" ;;
    D|d) bash "$ROOT/linux/16-auto-diagnose.sh" ;;
    F|f)
       read -r -p "确认执行安全自动修复？将先备份。[y/N]: " Y
       case "${Y:-n}" in y|Y|yes|YES) bash "$ROOT/linux/17-safe-auto-repair.sh" ;; *) echo "Cancelled." ;; esac
       ;;
    W|w)
       if [ -f /etc/proxy-runbook/public.env ]; then
         . /etc/proxy-runbook/public.env
       fi
       if [ -z "${COVER_DOMAIN:-}" ]; then
         read -r -p "Cover domain: " COVER_DOMAIN
       fi
       bash "$ROOT/linux/05b-cover-site-polished.sh" --list
       read -r -p "Template: R=random, A=stable per domain, 1-15=exact [R]: " COVER_TEMPLATE
       COVER_TEMPLATE="${COVER_TEMPLATE:-random}"
       bash "$ROOT/linux/05b-cover-site-polished.sh" "$COVER_DOMAIN" auto "$COVER_TEMPLATE" || {
         RC=$?
         if [ "$RC" -eq 20 ]; then
           read -r -p "Custom site exists. Replace after backup? [y/N]: " Y
           case "${Y:-n}" in y|Y|yes|YES) REPLACE_COVER=1 bash "$ROOT/linux/05b-cover-site-polished.sh" "$COVER_DOMAIN" auto "$COVER_TEMPLATE" ;; esac
         fi
       }
       [ -s "/etc/letsencrypt/live/${COVER_DOMAIN}/fullchain.pem" ] && bash "$ROOT/linux/05c-optimize-cover-backend.sh" "$COVER_DOMAIN" || true
       ;;
    V|v)
       bash "$ROOT/linux/20-adaptive-performance.sh" --detect
       read -r -p "A=自动应用，L=低内存，S=标准，H=高吞吐，R=回滚，其他=只检测: " P
       case "$P" in
         A|a) bash "$ROOT/linux/20-adaptive-performance.sh" --apply auto ;;
         L|l) bash "$ROOT/linux/20-adaptive-performance.sh" --apply low ;;
         S|s) bash "$ROOT/linux/20-adaptive-performance.sh" --apply standard ;;
         H|h) bash "$ROOT/linux/20-adaptive-performance.sh" --apply high ;;
         R|r) bash "$ROOT/linux/20-adaptive-performance.sh" --rollback ;;
       esac
       ;;
    T|t)
       bash "$ROOT/linux/21-traffic-status.sh" --status
       read -r -p "I=安装/初始化 vnStat，J=输出 JSON，其他=只看状态: " M
       case "$M" in
         I|i) bash "$ROOT/linux/21-traffic-status.sh" --install ;;
         J|j) bash "$ROOT/linux/21-traffic-status.sh" --json ;;
       esac
       ;;
    0) exit 0 ;;
    *) echo "无效选择。" ;;
  esac
  echo
  read -r -p "按 Enter 返回菜单..." _
done
