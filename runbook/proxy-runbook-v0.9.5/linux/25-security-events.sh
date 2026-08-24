#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

SINCE="24h"
CURSOR=0
LIMIT=200
OUTPUT="protocol-v1"

while [ "$#" -gt 0 ]; do
  case "$1" in
    --since) [ "$#" -ge 2 ] || exit 2; SINCE="$2"; shift 2 ;;
    --cursor) [ "$#" -ge 2 ] || exit 2; CURSOR="$2"; shift 2 ;;
    --limit) [ "$#" -ge 2 ] || exit 2; LIMIT="$2"; shift 2 ;;
    --protocol-v1) OUTPUT="protocol-v1"; shift ;;
    *) printf 'PNA_SECURITY_EVENTS_ERROR=INVALID_ARGUMENT\n' >&2; exit 2 ;;
  esac
done

case "$SINCE" in 1h|6h|24h|7d) ;; *) printf 'PNA_SECURITY_EVENTS_ERROR=INVALID_SINCE\n' >&2; exit 3 ;; esac
[[ "$CURSOR" =~ ^[0-9]+$ ]] && [ "$CURSOR" -le 100000 ] || { echo 'PNA_SECURITY_EVENTS_ERROR=INVALID_CURSOR' >&2; exit 3; }
[[ "$LIMIT" =~ ^[0-9]+$ ]] && [ "$LIMIT" -ge 1 ] && [ "$LIMIT" -le 1000 ] || { echo 'PNA_SECURITY_EVENTS_ERROR=INVALID_LIMIT' >&2; exit 3; }

case "$SINCE" in
  1h) JOURNAL_SINCE='1 hour ago' ;;
  6h) JOURNAL_SINCE='6 hours ago' ;;
  24h) JOURNAL_SINCE='24 hours ago' ;;
  7d) JOURNAL_SINCE='7 days ago' ;;
esac

WORK="$(mktemp -d)"
trap 'rm -rf -- "$WORK"' EXIT
EVENTS="$WORK/events.tsv"
SOURCES="$WORK/sources.tsv"
: > "$EVENTS"
: > "$SOURCES"

source_state() {
  printf 'SOURCE\t%s\t%s\t%s\n' "$1" "$2" "$3" >> "$SOURCES"
}

valid_ip() {
  [ "${#1}" -ge 2 ] && [ "${#1}" -le 45 ] && [[ "$1" =~ ^[0-9A-Fa-f:.]+$ ]]
}

add_event() {
  local category="$1" ip="$2" epoch="$3" detail="$4"
  valid_ip "$ip" || return 0
  [[ "$epoch" =~ ^[0-9]+$ ]] || epoch=0
  [[ "$category" =~ ^[A-Z0-9_]{3,48}$ ]] || return 0
  [[ "$detail" =~ ^[A-Za-z0-9_.:-]{1,64}$ ]] || detail=none
  printf '%s\t%s\t%s\t%s\n' "$category" "$ip" "$epoch" "$detail" >> "$EVENTS"
}

collect_ssh() {
  local log line ip epoch line_count
  if ! log="$(journalctl -u ssh -u sshd --since "$JOURNAL_SINCE" --no-pager -o short-unix -n 5000 2>/dev/null)"; then
    source_state SSH PARTIAL JOURNAL_UNAVAILABLE
    return
  fi
  while IFS= read -r line; do
    epoch="${line%%.*}"
    if [[ "$line" =~ Accepted[[:space:]](password|publickey)[[:space:]]for[[:space:]].*[[:space:]]from[[:space:]]([^[:space:]]+) ]]; then
      ip="${BASH_REMATCH[2]}"; add_event SSH_AUTH_SUCCESS "$ip" "$epoch" accepted
    elif [[ "$line" =~ Failed[[:space:]](password|publickey)[[:space:]]for.*[[:space:]]from[[:space:]]([^[:space:]]+) ]]; then
      ip="${BASH_REMATCH[2]}"; add_event SSH_AUTH_FAILURE "$ip" "$epoch" rejected
    fi
  done <<< "$log"
  line_count="$(wc -l <<< "$log" | tr -d ' ')"
  if [ "$line_count" -ge 5000 ]; then source_state SSH PARTIAL JOURNAL_TAIL_5000; else source_state SSH OK JOURNAL_PARSED; fi
}

collect_fail2ban() {
  local status ip now
  now="$(date +%s)"
  if ! command -v fail2ban-client >/dev/null 2>&1; then
    source_state FAIL2BAN PARTIAL NOT_INSTALLED
    return
  fi
  if ! status="$(fail2ban-client status sshd 2>/dev/null)"; then
    source_state FAIL2BAN PARTIAL SSHD_JAIL_UNAVAILABLE
    return
  fi
  while IFS= read -r ip; do
    [ -n "$ip" ] && add_event FAIL2BAN_BANNED "$ip" "$now" currently_banned
  done < <(sed -n 's/.*Banned IP list:[[:space:]]*//p' <<< "$status" | tr ' ' '\n')
  source_state FAIL2BAN OK SSHD_JAIL_ACTIVE
}

collect_kernel() {
  local log line ip epoch any=0 line_count
  if ! log="$(journalctl -k --since "$JOURNAL_SINCE" --no-pager -o short-unix -n 5000 2>/dev/null)"; then
    source_state FIREWALL PARTIAL KERNEL_JOURNAL_UNAVAILABLE
    return
  fi
  while IFS= read -r line; do
    epoch="${line%%.*}"
    if [[ "$line" == *'[UFW BLOCK]'* && "$line" =~ SRC=([^[:space:]]+) ]]; then
      ip="${BASH_REMATCH[1]}"; add_event FIREWALL_REJECT "$ip" "$epoch" ufw_block; any=1
    elif [[ "$line" == *'PNA-REALITY '* && "$line" =~ SRC=([^[:space:]]+) ]]; then
      ip="${BASH_REMATCH[1]}"; add_event REALITY_NEW_CONNECTION "$ip" "$epoch" tcp_syn; any=1
    fi
  done <<< "$log"
  line_count="$(wc -l <<< "$log" | tr -d ' ')"
  if [ "$line_count" -ge 5000 ]; then source_state FIREWALL PARTIAL JOURNAL_TAIL_5000
  elif [ "$any" -eq 1 ]; then source_state FIREWALL OK METADATA_PARSED
  else source_state FIREWALL OK NO_MATCHING_EVENTS; fi
}

collect_nginx() {
  local file=/var/log/nginx/proxy-node-assistant-security.log line ip epoch category
  if [ ! -e "$file" ]; then
    source_state NGINX INFO MANAGED_SECURITY_LOG_ABSENT
    return
  fi
  if [ ! -r "$file" ]; then
    source_state NGINX PARTIAL MANAGED_SECURITY_LOG_UNREADABLE
    return
  fi
  while IFS= read -r line; do
    [[ "$line" =~ ^epoch=([0-9]+)(\.[0-9]+)?[[:space:]]client_ip=([^[:space:]]+)[[:space:]]edge_ip=([^[:space:]]+)[[:space:]]method=([A-Z]+)[[:space:]]route_class=([a-z_]+)[[:space:]]status=([0-9]{3})[[:space:]]bytes=([0-9]+)[[:space:]]cf_ray=([A-Za-z0-9-]{0,64})$ ]] || continue
    epoch="${BASH_REMATCH[1]}"; ip="${BASH_REMATCH[3]}"; category="${BASH_REMATCH[6]}"
    case "$category" in xhttp) category=CDN_XHTTP_REQUEST ;; drive) category=PRIVATE_DRIVE_REQUEST ;; acme) category=ACME_REQUEST ;; *) category=WEB_REQUEST ;; esac
    add_event "$category" "$ip" "$epoch" "http_${BASH_REMATCH[7]}"
  done < <(tail -n 5000 "$file")
  if [ "$(wc -l < "$file" | tr -d ' ')" -gt 5000 ]; then source_state NGINX PARTIAL SANITIZED_LOG_TAIL_5000
  else source_state NGINX OK SANITIZED_LOG_PARSED; fi
}

collect_current() {
  local line local_addr peer ip now category any=0
  now="$(date +%s)"
  while IFS= read -r line; do
    local_addr="$(awk '{print $(NF-1)}' <<< "$line")"
    peer="$(awk '{print $NF}' <<< "$line")"
    ip="$peer"
    if [[ "$peer" == \[*\]:* ]]; then ip="${peer#\[}"; ip="${ip%%\]*}"; else ip="${peer%:*}"; fi
    case "$local_addr" in *:22|*:2222) category=CURRENT_SSH_CONNECTION ;; *:443) category=CURRENT_443_CONNECTION ;; *) continue ;; esac
    add_event "$category" "$ip" "$now" snapshot; any=1
  done < <(ss -H -nt state established 2>/dev/null || true)
  if [ "$any" -eq 1 ]; then source_state CONNECTIONS OK SNAPSHOT_CAPTURED; else source_state CONNECTIONS OK NO_CURRENT_CONNECTIONS; fi
}

collect_ssh
collect_fail2ban
collect_kernel
collect_nginx
collect_current

AGG="$WORK/aggregated.tsv"
awk -F '\t' '
  { key=$1 FS $2 FS $4; count[key]++; if ($3>last[key]) last[key]=$3 }
  END { for (key in count) { split(key,a,FS); printf "%s\t%s\t%d\t%d\t%s\n",a[1],a[2],count[key],last[key],a[3] } }
' "$EVENTS" | sort -t $'\t' -k3,3nr -k4,4nr -k1,1 -k2,2 > "$AGG"

TOTAL="$(wc -l < "$AGG" | tr -d ' ')"
END=$((CURSOR + LIMIT))
if [ "$END" -lt "$TOTAL" ]; then TRUNCATED=1; NEXT_CURSOR="$END"; else TRUNCATED=0; NEXT_CURSOR=""; fi

echo '__PNA_SECURITY_V1_BEGIN__'
printf 'META\tSINCE=%s\tCURSOR=%s\tLIMIT=%s\n' "$SINCE" "$CURSOR" "$LIMIT"
cat "$SOURCES"
awk -F '\t' -v offset="$CURSOR" -v limit="$LIMIT" 'NR>offset && NR<=offset+limit {printf "EVENT\t%s\t%s\t%s\t%s\t%s\n",$1,$2,$3,$4,$5}' "$AGG"
printf 'SUMMARY\tTOTAL=%s\tRETURNED=%s\tTRUNCATED=%s\tNEXT_CURSOR=%s\n' \
  "$TOTAL" "$(awk -v offset="$CURSOR" -v limit="$LIMIT" 'NR>offset && NR<=offset+limit {n++} END{print n+0}' "$AGG")" "$TRUNCATED" "$NEXT_CURSOR"
echo '__PNA_SECURITY_V1_END__'
