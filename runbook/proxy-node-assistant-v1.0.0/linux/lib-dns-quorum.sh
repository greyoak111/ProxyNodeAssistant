#!/usr/bin/env bash

# Resolver adapters are separate functions so the quorum policy can be tested
# offline without replacing curl/getent globally.
tna_dns_system_answers() {
  getent ahostsv4 "$1" 2>/dev/null | awk '{print $1}' | sort -u
}

tna_dns_cloudflare_answers() {
  curl --noproxy '*' -4fsS --max-time 8 \
    -H 'accept: application/dns-json' --get \
    --data-urlencode "name=$1" --data-urlencode 'type=A' \
    https://cloudflare-dns.com/dns-query 2>/dev/null \
    | jq -r '.Answer[]? | select(.type == 1) | .data' 2>/dev/null \
    | sort -u
}

tna_dns_google_answers() {
  curl --noproxy '*' -4fsS --max-time 8 --get \
    --data-urlencode "name=$1" --data-urlencode 'type=A' \
    https://dns.google/resolve 2>/dev/null \
    | jq -r '.Answer[]? | select(.type == 1) | .data' 2>/dev/null \
    | sort -u
}

tna_dns_answer_matches() {
  local resolver="$1" name="$2" expected="$3" answers
  answers="$($resolver "$name" || true)"
  grep -Fxq -- "$expected" <<<"$answers"
}

dns_points_to_ipv4_quorum() {
  local name="$1" expected="$2"
  # The VPS resolver remains the fastest path. If it is stale or broken, two
  # independent public resolvers must agree before construction continues.
  tna_dns_answer_matches tna_dns_system_answers "$name" "$expected" && return 0
  tna_dns_answer_matches tna_dns_cloudflare_answers "$name" "$expected" &&
    tna_dns_answer_matches tna_dns_google_answers "$name" "$expected"
}

dns_print_quorum_observation() {
  local name="$1" expected="$2" system=MISS cloudflare=MISS google=MISS
  tna_dns_answer_matches tna_dns_system_answers "$name" "$expected" && system=MATCH
  tna_dns_answer_matches tna_dns_cloudflare_answers "$name" "$expected" && cloudflare=MATCH
  tna_dns_answer_matches tna_dns_google_answers "$name" "$expected" && google=MATCH
  printf 'DNS_RESOLVER_OBSERVATION system=%s cloudflare=%s google=%s\n' "$system" "$cloudflare" "$google"
}
