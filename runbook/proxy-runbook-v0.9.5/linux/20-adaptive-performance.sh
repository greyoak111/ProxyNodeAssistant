#!/usr/bin/env bash
set -Eeuo pipefail

[ "$(id -u)" -eq 0 ] || { echo "ERROR: run as root (or sudo)."; exit 1; }

STATE_DIR="/root/.config/proxy-runbook"
STATE_FILE="$STATE_DIR/performance-profile.env"
LAST_BACKUP_FILE="$STATE_DIR/performance-last-backup"
BACKUP_ROOT="/root/proxy-runbook-performance-backups"
SYSCTL_OLD="/etc/sysctl.d/99-proxy-runbook.conf"
SYSCTL_FILE="/etc/sysctl.d/99-proxy-runbook-performance.conf"
XUI_OVERRIDE="/etc/systemd/system/x-ui.service.d/90-proxy-runbook-performance.conf"
NGINX_OVERRIDE="/etc/systemd/system/nginx.service.d/90-proxy-runbook-performance.conf"
NGINX_CONF="/etc/nginx/nginx.conf"
ZRAM_UNIT="/etc/systemd/system/proxy-runbook-zram.service"

mkdir -p "$STATE_DIR" "$BACKUP_ROOT"
chmod 700 "$STATE_DIR" "$BACKUP_ROOT"

mem_mb() {
  awk '/^MemTotal:/ { printf "%d\n", $2 / 1024 }' /proc/meminfo
}

cpu_count() {
  nproc 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1
}

detect_profile() {
  local memory cpus
  memory="$(mem_mb)"
  cpus="$(cpu_count)"
  if [ "$memory" -le 1536 ]; then
    echo low
  elif [ "$memory" -ge 4096 ] && [ "$cpus" -ge 4 ]; then
    echo high
  else
    echo standard
  fi
}

profile_values() {
  case "$1" in
    low)
      SOMAXCONN=2048; BACKLOG=4096; SYN_BACKLOG=2048; SOCKET_MAX=16777216
      WORKER_CONNECTIONS=2048; FILE_MAX=262144; SWAPPINESS=20; ZRAM_MB=384
      ;;
    standard)
      SOMAXCONN=4096; BACKLOG=8192; SYN_BACKLOG=4096; SOCKET_MAX=33554432
      WORKER_CONNECTIONS=4096; FILE_MAX=524288; SWAPPINESS=10; ZRAM_MB=0
      ;;
    high)
      SOMAXCONN=8192; BACKLOG=16384; SYN_BACKLOG=8192; SOCKET_MAX=67108864
      WORKER_CONNECTIONS=8192; FILE_MAX=1048576; SWAPPINESS=10; ZRAM_MB=0
      ;;
    *) echo "ERROR: unknown profile '$1'"; exit 2 ;;
  esac
}

show_detection() {
  local available current_cc current_qdisc
  available="$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || echo unknown)"
  current_cc="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo unknown)"
  current_qdisc="$(sysctl -n net.core.default_qdisc 2>/dev/null || echo unknown)"
  echo "PERFORMANCE_DETECT_OK"
  echo "MEMORY_MB=$(mem_mb)"
  echo "CPU_COUNT=$(cpu_count)"
  echo "AUTO_PROFILE=$(detect_profile)"
  echo "AVAILABLE_CONGESTION=$available"
  echo "CURRENT_CONGESTION=$current_cc"
  echo "CURRENT_QDISC=$current_qdisc"
  echo "VIRTUALIZATION=$(systemd-detect-virt 2>/dev/null || echo unknown)"
  if [ -f "$STATE_FILE" ]; then
    sed -n 's/^/STATE_/p' "$STATE_FILE"
  else
    echo "STATE_PROFILE=UNMANAGED"
  fi
}

backup_one() {
  local source="$1" name="$2" backup="$3"
  if [ -e "$source" ]; then
    cp -a "$source" "$backup/$name"
    : > "$backup/$name.present"
  fi
}

create_backup() {
  local backup="$BACKUP_ROOT/$(date -u +%Y%m%d-%H%M%S)-$$" key value
  mkdir -p "$backup"
  chmod 700 "$backup"
  backup_one "$SYSCTL_OLD" sysctl-old.conf "$backup"
  backup_one "$SYSCTL_FILE" sysctl-performance.conf "$backup"
  backup_one "$XUI_OVERRIDE" x-ui-override.conf "$backup"
  backup_one "$NGINX_OVERRIDE" nginx-override.conf "$backup"
  backup_one "$NGINX_CONF" nginx.conf "$backup"
  backup_one "$ZRAM_UNIT" zram.service "$backup"
  backup_one "$STATE_FILE" performance-profile.env "$backup"
  for key in \
    net.core.somaxconn net.core.netdev_max_backlog net.ipv4.tcp_max_syn_backlog \
    net.core.rmem_max net.core.wmem_max net.ipv4.tcp_rmem net.ipv4.tcp_wmem \
    net.ipv4.tcp_mtu_probing fs.file-max vm.swappiness \
    net.core.default_qdisc net.ipv4.tcp_congestion_control; do
    value="$(sysctl -n "$key" 2>/dev/null || true)"
    [ -n "$value" ] && printf '%s\t%s\n' "$key" "$value" >> "$backup/runtime-sysctl.tsv"
  done
  if systemctl is-active --quiet proxy-runbook-zram.service 2>/dev/null; then
    : > "$backup/zram.was-active"
  fi
  printf '%s\n' "$backup"
}

restore_one() {
  local target="$1" name="$2" backup="$3"
  if [ -f "$backup/$name.present" ]; then
    mkdir -p "$(dirname "$target")"
    cp -a "$backup/$name" "$target"
  else
    rm -f "$target"
  fi
}

restore_backup() {
  local backup="$1"
  [ -d "$backup" ] || { echo "ERROR: backup directory is missing: $backup"; return 1; }
  systemctl disable --now proxy-runbook-zram.service >/dev/null 2>&1 || true
  restore_one "$SYSCTL_OLD" sysctl-old.conf "$backup"
  restore_one "$SYSCTL_FILE" sysctl-performance.conf "$backup"
  restore_one "$XUI_OVERRIDE" x-ui-override.conf "$backup"
  restore_one "$NGINX_OVERRIDE" nginx-override.conf "$backup"
  restore_one "$NGINX_CONF" nginx.conf "$backup"
  restore_one "$ZRAM_UNIT" zram.service "$backup"
  restore_one "$STATE_FILE" performance-profile.env "$backup"
  systemctl daemon-reload
  if [ -f "$backup/zram.was-active" ] && [ -f "$ZRAM_UNIT" ]; then
    systemctl enable --now proxy-runbook-zram.service >/dev/null 2>&1 || true
  fi
  if [ -s "$backup/runtime-sysctl.tsv" ]; then
    while IFS=$'\t' read -r key value; do
      [ -n "$key" ] || continue
      sysctl -w "$key=$value" >/dev/null 2>&1 || true
    done < "$backup/runtime-sysctl.tsv"
  fi
  if command -v nginx >/dev/null 2>&1; then
    nginx -t
    systemctl try-reload-or-restart nginx >/dev/null 2>&1 || true
  fi
  systemctl try-restart x-ui >/dev/null 2>&1 || true
  echo "PERFORMANCE_ROLLBACK_OK backup=$backup"
}

write_zram_unit() {
  local size_mb="$1"
  cat > "$ZRAM_UNIT" <<EOF
[Unit]
Description=ProxyNodeAssistant bounded low-memory zram swap
After=local-fs.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/bash -c 'modprobe zram; swapon --noheadings --show=NAME | grep -q "^/dev/zram" && exit 0; dev=\$(zramctl --find --size ${size_mb}M --algorithm zstd 2>/dev/null || zramctl --find --size ${size_mb}M); mkswap \"\$dev\" >/dev/null; swapon -p 100 \"\$dev\"'
ExecStop=/bin/bash -c 'for dev in \$(swapon --noheadings --show=NAME | grep "^/dev/zram" || true); do swapoff \"\$dev\" || true; zramctl --reset \"\$dev\" || true; done'

[Install]
WantedBy=multi-user.target
EOF
  chmod 644 "$ZRAM_UNIT"
}

apply_profile() {
  local requested="$1" profile backup applying=0
  if [ "$requested" = auto ]; then profile="$(detect_profile)"; else profile="$requested"; fi
  profile_values "$profile"
  backup="$(create_backup)"
  printf '%s\n' "$backup" > "$LAST_BACKUP_FILE"
  chmod 600 "$LAST_BACKUP_FILE"
  applying=1
  trap 'rc=$?; if [ "$applying" -eq 1 ]; then echo "PERFORMANCE_APPLY_FAILED rc=$rc; rolling back" >&2; restore_backup "$backup" || true; fi; exit "$rc"' ERR

  modprobe tcp_bbr 2>/dev/null || true
  {
    echo '# Managed by ProxyNodeAssistant v0.9.5. Use menu [16] to change or roll back.'
    echo "net.core.somaxconn=$SOMAXCONN"
    echo "net.core.netdev_max_backlog=$BACKLOG"
    echo "net.ipv4.tcp_max_syn_backlog=$SYN_BACKLOG"
    echo "net.core.rmem_max=$SOCKET_MAX"
    echo "net.core.wmem_max=$SOCKET_MAX"
    echo "net.ipv4.tcp_rmem=4096 131072 $SOCKET_MAX"
    echo "net.ipv4.tcp_wmem=4096 65536 $SOCKET_MAX"
    echo 'net.ipv4.tcp_mtu_probing=1'
    echo "fs.file-max=$FILE_MAX"
    echo "vm.swappiness=$SWAPPINESS"
    if sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null | grep -qw bbr; then
      echo 'net.core.default_qdisc=fq'
      echo 'net.ipv4.tcp_congestion_control=bbr'
    fi
  } > "$SYSCTL_FILE"
  chmod 644 "$SYSCTL_FILE"
  rm -f "$SYSCTL_OLD"
  sysctl -p "$SYSCTL_FILE" >/dev/null

  mkdir -p "$(dirname "$XUI_OVERRIDE")" "$(dirname "$NGINX_OVERRIDE")"
  printf '[Service]\nLimitNOFILE=65535\n' > "$XUI_OVERRIDE"
  printf '[Service]\nLimitNOFILE=65535\n' > "$NGINX_OVERRIDE"
  chmod 644 "$XUI_OVERRIDE" "$NGINX_OVERRIDE"

  if command -v nginx >/dev/null 2>&1 && [ -f "$NGINX_CONF" ]; then
    sed -i -E 's/^[[:space:]]*worker_processes[[:space:]]+[^;]+;/worker_processes auto;/' "$NGINX_CONF"
    if grep -qE '^[[:space:]]*worker_connections[[:space:]]+[0-9]+;' "$NGINX_CONF"; then
      sed -i -E "s/^([[:space:]]*)worker_connections[[:space:]]+[0-9]+;/\\1worker_connections $WORKER_CONNECTIONS;/" "$NGINX_CONF"
    fi
    nginx -t
  fi

  if [ "$ZRAM_MB" -gt 0 ] && command -v zramctl >/dev/null 2>&1 && modprobe zram 2>/dev/null; then
    write_zram_unit "$ZRAM_MB"
    systemctl daemon-reload
    systemctl enable --now proxy-runbook-zram.service >/dev/null
    ZRAM_STATUS="managed-${ZRAM_MB}M"
  else
    systemctl disable --now proxy-runbook-zram.service >/dev/null 2>&1 || true
    rm -f "$ZRAM_UNIT"
    ZRAM_STATUS="disabled-or-unavailable"
  fi

  systemctl daemon-reload
  systemctl try-restart x-ui >/dev/null 2>&1 || true
  systemctl try-reload-or-restart nginx >/dev/null 2>&1 || true

  cat > "$STATE_FILE" <<EOF
PROFILE=$profile
REQUESTED_PROFILE=$requested
MEMORY_MB=$(mem_mb)
CPU_COUNT=$(cpu_count)
SOMAXCONN=$SOMAXCONN
SOCKET_MAX=$SOCKET_MAX
NGINX_WORKER_CONNECTIONS=$WORKER_CONNECTIONS
ZRAM_STATUS=$ZRAM_STATUS
BACKUP_DIR=$backup
APPLIED_AT_UTC=$(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF
  chmod 600 "$STATE_FILE"
  applying=0
  trap - ERR
  echo "PERFORMANCE_APPLY_OK profile=$profile backup=$backup zram=$ZRAM_STATUS"
  show_detection
}

case "${1:---detect}" in
  --detect|--status)
    show_detection
    ;;
  --apply)
    apply_profile "${2:-auto}"
    ;;
  --rollback)
    [ -s "$LAST_BACKUP_FILE" ] || { echo "ERROR: no managed performance backup is recorded"; exit 3; }
    restore_backup "$(cat "$LAST_BACKUP_FILE")"
    ;;
  *)
    echo "Usage: $0 --detect | --status | --apply auto|low|standard|high | --rollback"
    exit 2
    ;;
esac
