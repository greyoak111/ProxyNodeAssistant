#!/usr/bin/env bash
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# The maintenance menu is itself a root-side entry point.  Keep its custom
# credential path equivalent to the desktop/Android clients: secrets are
# masked at input, written only as base64 in a root-owned one-run file, and
# never interpolated into a command argument or environment value.  The
# rotation scripts validate the file again and remove it on their own EXIT
# path; this menu-level trap is the last-resort cleanup if the child fails.
CREDENTIAL_INPUT=""
CREDENTIAL_MODE=""
CREDENTIAL_SECRET=""
CREDENTIAL_ACCOUNT=""

cleanup_credential_input() {
  local path="${CREDENTIAL_INPUT:-}"
  if [[ "$path" =~ ^/tmp/proxy-node-assistant-credential-input-[0-9a-f]{6,64}$ ]]; then
    rm -f -- "$path" 2>/dev/null || true
  fi
  CREDENTIAL_INPUT=""
}

trap cleanup_credential_input EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

clear_credential_values() {
  # Bash cannot guarantee a memory wipe, but dropping the references ensures
  # cancelled/finished menu iterations do not retain usable shell variables.
  CREDENTIAL_SECRET=""
  CREDENTIAL_ACCOUNT=""
  CREDENTIAL_MODE=""
}

credential_b64() {
  local value="$1"
  command -v base64 >/dev/null 2>&1 || return 1
  # `base64` may wrap long values; removing line breaks still yields one valid
  # value per handoff input line and preserves every byte of the secret.
  printf '%s' "$value" | base64 | tr -d '\r\n'
}

create_credential_input() {
  local nonce path line
  [ "$(id -u)" -eq 0 ] || return 1
  [ "$#" -gt 0 ] || return 1
  nonce="$(openssl rand -hex 16 2>/dev/null)" || return 1
  [[ "$nonce" =~ ^[0-9a-f]{32}$ ]] || return 1
  path="/tmp/proxy-node-assistant-credential-input-${nonce}"
  for line in "$@"; do
    case "$line" in *$'\r'*|*$'\n'*) return 1 ;; esac
  done
  # noclobber makes the open O_EXCL, so an existing file/symlink cannot be
  # replaced between name generation and the write.
  if ! ( umask 077; set -o noclobber; printf '%s\n' "$@" > "$path" ); then
    rm -f -- "$path" 2>/dev/null || true
    return 1
  fi
  if ! chmod 600 -- "$path"; then
    rm -f -- "$path" 2>/dev/null || true
    return 1
  fi
  CREDENTIAL_INPUT="$path"
}

valid_credential_secret() {
  local value="$1"
  case "$value" in ''|*$'\r'*|*$'\n'*) return 1 ;; esac
  [ "${#value}" -ge 8 ] && [ "${#value}" -le 256 ]
}

read_matching_secret() {
  local label="$1" first="" second=""
  IFS= read -r -s -p "${label}: " first || { printf '\n'; return 1; }
  printf '\n'
  IFS= read -r -s -p "再次输入 / Repeat ${label}: " second || { printf '\n'; return 1; }
  printf '\n'
  if [ "$first" != "$second" ]; then
    echo "两次输入不一致，已取消。 / Values did not match; cancelled."
    return 1
  fi
  if ! valid_credential_secret "$first"; then
    echo "密码必须为 8—256 个字符且不能含换行。 / Password must be 8-256 characters without newlines."
    return 1
  fi
  CREDENTIAL_SECRET="$first"
}

choose_credential_mode() {
  local answer=""
  CREDENTIAL_MODE=""
  echo "凭据策略 / Credential policy:"
  echo "  1) 生成新的随机值 / Generate a new random value"
  echo "  2) 自定义值（密码遮罩 + 二次确认）/ Custom value (masked + repeat)"
  echo "  0) 取消 / Cancel"
  while true; do
    IFS= read -r -p "选择 [1/2/0]: " answer || return 1
    case "${answer,,}" in
      1|r|random) CREDENTIAL_MODE="random"; return 0 ;;
      2|c|custom) CREDENTIAL_MODE="custom"; return 0 ;;
      0|q|quit|cancel) CREDENTIAL_MODE="cancel"; return 0 ;;
      *) echo "请输入 1、2 或 0。 / Enter 1, 2, or 0." ;;
    esac
  done
}

confirm_credential_change() {
  local prompt="$1" answer=""
  IFS= read -r -p "${prompt} [y/N]: " answer || { printf '\n'; return 1; }
  case "${answer,,}" in y|yes) return 0 ;; *) return 1 ;; esac
}

show_custom_handoff() {
  . "$ROOT/linux/lib-handoff.sh"
  handoff_show
}

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
P) 生成/轮换 VPS 登录密码（随机/自定义/取消）并显示
X) 生成/轮换 3x-ui 用户名密码（随机/自定义/取消）并显示
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
       U=""
       IFS= read -r -p "要轮换密码的 VPS 用户名: " U || U=""
       if [ -n "$U" ]; then
         if choose_credential_mode && [ "$CREDENTIAL_MODE" != "cancel" ]; then
           if [ "$CREDENTIAL_MODE" = "custom" ]; then
             if read_matching_secret "自定义 VPS 登录密码 / Custom VPS login password"; then
               if confirm_credential_change "确认立即写入自定义 VPS 登录密码？SSH key 已存在，不会因此失联。 / Apply the custom VPS login password now?"; then
                 encoded="$(credential_b64 "$CREDENTIAL_SECRET")" || encoded=""
                 if [ -n "$encoded" ] && create_credential_input "VPS_PASSWORD_B64=$encoded"; then
                   PNA_VPS_PASSWORD_MODE=custom PNA_CREDENTIAL_INPUT="$CREDENTIAL_INPUT" \
                     bash "$ROOT/linux/01a-rotate-vps-password.sh" "$U"
                   rc=$?
                   cleanup_credential_input
                   [ "$rc" -eq 0 ] && show_custom_handoff
                 else
                   echo "无法创建安全的一次性凭据文件，未修改远端。 / Could not create the secure one-run credential file; remote was not changed."
                 fi
               else
                 echo "已取消，未修改远端。 / Cancelled; remote was not changed."
               fi
             fi
           elif confirm_credential_change "确认生成高强度随机 VPS 登录密码并立即写入？SSH key 已存在，不会因此失联。 / Generate and apply a random VPS login password now?"; then
             PNA_VPS_PASSWORD_MODE=random bash "$ROOT/linux/01a-rotate-vps-password.sh" "$U"
           fi
         else
           echo "已取消，未修改远端。 / Cancelled; remote was not changed."
         fi
       fi
       clear_credential_values
       ;;
    X|x)
       if choose_credential_mode && [ "$CREDENTIAL_MODE" != "cancel" ]; then
         if [ "$CREDENTIAL_MODE" = "custom" ]; then
           CREDENTIAL_ACCOUNT=""
           IFS= read -r -p "自定义 3x-ui 账号（字母/数字/._-，首字符为字母或下划线）: " CREDENTIAL_ACCOUNT || CREDENTIAL_ACCOUNT=""
           if [[ "$CREDENTIAL_ACCOUNT" =~ ^[A-Za-z_][A-Za-z0-9_.-]{0,63}$ ]]; then
             if read_matching_secret "自定义 3x-ui 面板密码 / Custom 3x-ui panel password"; then
               if confirm_credential_change "确认立即写入自定义 3x-ui 账号和密码？现有会话会退出。 / Apply the custom 3x-ui username and password now?"; then
                 account_encoded="$(credential_b64 "$CREDENTIAL_ACCOUNT")" || account_encoded=""
                 password_encoded="$(credential_b64 "$CREDENTIAL_SECRET")" || password_encoded=""
                 if [ -n "$account_encoded" ] && [ -n "$password_encoded" ] && create_credential_input \
                     "PANEL_USERNAME_B64=$account_encoded" "PANEL_PASSWORD_B64=$password_encoded"; then
                   PNA_PANEL_CREDENTIAL_MODE=custom PNA_CREDENTIAL_INPUT="$CREDENTIAL_INPUT" \
                     bash "$ROOT/linux/03c-rotate-panel-credentials.sh"
                   rc=$?
                   cleanup_credential_input
                   [ "$rc" -eq 0 ] && show_custom_handoff
                 else
                   echo "无法创建安全的一次性凭据文件，未修改远端。 / Could not create the secure one-run credential file; remote was not changed."
                 fi
               else
                 echo "已取消，未修改远端。 / Cancelled; remote was not changed."
               fi
             fi
           else
             echo "面板账号格式无效，未修改远端。 / Invalid panel username; remote was not changed."
           fi
         elif confirm_credential_change "确认生成并应用新的随机 3x-ui 账号和密码？现有会话会退出。 / Generate and apply random 3x-ui credentials now?"; then
           PNA_PANEL_CREDENTIAL_MODE=random bash "$ROOT/linux/03c-rotate-panel-credentials.sh"
         fi
       else
         echo "已取消，未修改远端。 / Cancelled; remote was not changed."
       fi
       clear_credential_values
       ;;
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
