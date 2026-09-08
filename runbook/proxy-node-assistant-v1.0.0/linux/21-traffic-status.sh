#!/usr/bin/env bash
set -Eeuo pipefail

[ "$(id -u)" -eq 0 ] || { echo "ERROR: run as root (or sudo)."; exit 1; }

default_interface() {
  ip -4 route show default 2>/dev/null | awk 'NR==1 {print $5}'
}

interface="${PROXY_RUNBOOK_TRAFFIC_INTERFACE:-$(default_interface)}"
[ -n "$interface" ] || { echo "ERROR: cannot determine the default IPv4 interface" >&2; exit 2; }

ensure_database() {
  if vnstat -i "$interface" --json d >/dev/null 2>&1; then
    return 0
  fi
  vnstat --add -i "$interface" >/dev/null 2>&1 || true
  systemctl restart vnstat >/dev/null 2>&1 || true
  sleep 2
}

case "${1:---status}" in
  --install)
    if ! command -v vnstat >/dev/null 2>&1; then
      export DEBIAN_FRONTEND=noninteractive
      apt-get update
      apt-get install -y vnstat
    fi
    systemctl enable --now vnstat >/dev/null 2>&1 || true
    ensure_database
    echo "VNSTAT_INSTALL_OK interface=$interface"
    ;;
  --status)
    echo "TRAFFIC_INTERFACE=$interface"
    if command -v vnstat >/dev/null 2>&1; then
      echo "VNSTAT_INSTALLED=1"
      echo "VNSTAT_VERSION=$(vnstat --version 2>/dev/null | sed -n '1p')"
      if vnstat -i "$interface" --json d >/dev/null 2>&1; then
        echo "VNSTAT_DATABASE_READY=1"
      else
        echo "VNSTAT_DATABASE_READY=0"
      fi
    else
      echo "VNSTAT_INSTALLED=0"
      echo "VNSTAT_DATABASE_READY=0"
    fi
    ;;
  --json)
    command -v vnstat >/dev/null 2>&1 || { echo "ERROR: vnStat is not installed" >&2; exit 4; }
    ensure_database
    vnstat -i "$interface" --json d
    ;;
  *)
    echo "Usage: $0 --install | --status | --json"
    exit 2
    ;;
esac
