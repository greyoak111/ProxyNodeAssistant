#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=../runbook/proxy-runbook-v0.9.5/linux/lib-dns-quorum.sh
. "$ROOT/runbook/proxy-runbook-v0.9.5/linux/lib-dns-quorum.sh"

SYSTEM_ANSWERS=''
CLOUDFLARE_ANSWERS=''
GOOGLE_ANSWERS=''
pna_dns_system_answers() { printf '%s\n' "$SYSTEM_ANSWERS"; }
pna_dns_cloudflare_answers() { printf '%s\n' "$CLOUDFLARE_ANSWERS"; }
pna_dns_google_answers() { printf '%s\n' "$GOOGLE_ANSWERS"; }

expected=203.0.113.10
SYSTEM_ANSWERS="$expected"
dns_points_to_ipv4_quorum example.invalid "$expected"

SYSTEM_ANSWERS=203.0.113.11
CLOUDFLARE_ANSWERS="$expected"
GOOGLE_ANSWERS="$expected"
dns_points_to_ipv4_quorum example.invalid "$expected"

GOOGLE_ANSWERS=203.0.113.12
if dns_points_to_ipv4_quorum example.invalid "$expected"; then
  echo 'one public resolver was incorrectly accepted' >&2
  exit 1
fi

SYSTEM_ANSWERS='203.0.113.100'
CLOUDFLARE_ANSWERS='203.0.113.100'
GOOGLE_ANSWERS='203.0.113.100'
if dns_points_to_ipv4_quorum example.invalid "$expected"; then
  echo 'a prefix/non-matching address was incorrectly accepted' >&2
  exit 1
fi

echo DNS_QUORUM_TEST_OK
