#!/usr/bin/env bash
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
  echo "Run as root."
  exit 1
fi

. /etc/os-release
CODENAME="${VERSION_CODENAME:-}"
if [ -z "$CODENAME" ]; then
  echo "Cannot determine VERSION_CODENAME."
  exit 1
fi

KEYRING="/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg"
SOURCE_LIST="/etc/apt/sources.list.d/cloudflare-client.list"
DISABLED_SOURCE="${SOURCE_LIST}.proxy-runbook-disabled"
TMP_ASC=""
TMP_GPG=""

cleanup() {
  rm -f "${TMP_ASC:-}" "${TMP_GPG:-}"
  if [ -f "$DISABLED_SOURCE" ] && [ ! -f "$SOURCE_LIST" ]; then
    mv "$DISABLED_SOURCE" "$SOURCE_LIST"
  fi
}
trap cleanup EXIT

# An old Cloudflare source can make the very first apt-get update fail before
# this script gets a chance to refresh Cloudflare's rotated signing key. Only
# hide that one known source while bootstrapping missing HTTPS/GPG tools.
if ! command -v curl >/dev/null 2>&1 || ! command -v gpg >/dev/null 2>&1; then
  if [ -f "$SOURCE_LIST" ]; then
    rm -f "$DISABLED_SOURCE"
    mv "$SOURCE_LIST" "$DISABLED_SOURCE"
  fi
  apt-get update
  apt-get install -y curl gnupg lsb-release ca-certificates
fi

install -d -m 755 /usr/share/keyrings /etc/apt/sources.list.d
TMP_ASC="$(mktemp)"
TMP_GPG="$(mktemp)"
curl -fsSL https://pkg.cloudflareclient.com/pubkey.gpg -o "$TMP_ASC"
gpg --batch --yes --dearmor --output "$TMP_GPG" "$TMP_ASC"
test -s "$TMP_GPG"
install -o root -g root -m 644 "$TMP_GPG" "$KEYRING"

printf 'deb [signed-by=%s] https://pkg.cloudflareclient.com/ %s main\n' \
  "$KEYRING" "$CODENAME" > "$SOURCE_LIST"
rm -f "$DISABLED_SOURCE"

echo "CLOUDFLARE_WARP_KEYRING_REFRESHED"

apt-get update
apt-get install -y cloudflare-warp
systemctl enable --now warp-svc

echo "===== VERIFY ====="
warp-cli --version
systemctl is-active warp-svc
echo "WARP_INSTALL_OK"

trap - EXIT
cleanup
