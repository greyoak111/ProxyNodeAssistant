#!/usr/bin/env bash

# Pinned third-party downloader shared by the unattended installer and the
# standalone 3x-ui installer. The upstream installer is retained, but every
# byte it consumes is downloaded from an immutable release/commit and checked
# before the installer is allowed to replace an existing binary.

pna_load_third_party_lock() {
  local lock_file="${1:?toolkit root is required}/THIRD_PARTY_LOCK.env"
  [ -r "$lock_file" ] || { echo "PNA_SUPPLY_CHAIN_ERROR=LOCK_MISSING" >&2; return 71; }
  # shellcheck disable=SC1090
  . "$lock_file"

  case "${THREEXUI_VERSION:-}" in v[0-9]*.[0-9]*.[0-9]*) ;; *) return 72;; esac
  case "${THREEXUI_COMMIT:-}" in [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]*) ;; *) return 72;; esac
  for value in \
    "${THREEXUI_INSTALLER_SHA256:-}" "${THREEXUI_SCRIPT_SHA256:-}" \
    "${THREEXUI_ASSET_SHA256_386:-}" "${THREEXUI_ASSET_SHA256_AMD64:-}" \
    "${THREEXUI_ASSET_SHA256_ARM64:-}" "${THREEXUI_ASSET_SHA256_ARMV5:-}" \
    "${THREEXUI_ASSET_SHA256_ARMV6:-}" "${THREEXUI_ASSET_SHA256_ARMV7:-}" \
    "${THREEXUI_ASSET_SHA256_S390X:-}"; do
    case "$value" in
      [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]*) [ "${#value}" -eq 64 ] || return 72 ;;
      *) return 72 ;;
    esac
  done

  case "${COPYPARTY_VERSION:-}" in v[0-9]*.[0-9]*.[0-9]*) ;; *) return 72;; esac
  case "${COPYPARTY_SFX_URL:-}" in https://github.com/9001/copyparty/releases/download/*/copyparty-sfx.py) ;; *) return 72;; esac
  case "${COPYPARTY_SFX_SHA256:-}" in
    [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]*) [ "${#COPYPARTY_SFX_SHA256}" -eq 64 ] || return 72 ;;
    *) return 72 ;;
  esac
  case "${COPYPARTY_SFX_SIZE:-}" in ''|*[!0-9]*) return 72;; esac
}

pna_3xui_arch() {
  case "$(uname -m)" in
    i386|i486|i586|i686) printf '%s\n' 386 ;;
    x86_64|amd64) printf '%s\n' amd64 ;;
    aarch64|arm64) printf '%s\n' arm64 ;;
    armv5*|armv5l) printf '%s\n' armv5 ;;
    armv6*|armv6l) printf '%s\n' armv6 ;;
    armv7*|armv7l) printf '%s\n' armv7 ;;
    s390x) printf '%s\n' s390x ;;
    *) echo "PNA_SUPPLY_CHAIN_ERROR=UNSUPPORTED_ARCH $(uname -m)" >&2; return 73 ;;
  esac
}

pna_sha256_check() {
  local expected="${1:?expected hash is required}" file="${2:?file is required}"
  printf '%s  %s\n' "$expected" "$file" | sha256sum -c - >/dev/null
}

pna_install_3xui_pinned() (
  set -Eeuo pipefail
  local toolkit_root="${1:?toolkit root is required}" arch asset_hash tmp installer upstream_script archive
  command -v curl >/dev/null 2>&1 || { echo "PNA_SUPPLY_CHAIN_ERROR=CURL_MISSING" >&2; exit 74; }
  command -v sha256sum >/dev/null 2>&1 || { echo "PNA_SUPPLY_CHAIN_ERROR=SHA256SUM_MISSING" >&2; exit 74; }
  pna_load_third_party_lock "$toolkit_root"
  arch="$(pna_3xui_arch)"
  case "$arch" in
    386) asset_hash="$THREEXUI_ASSET_SHA256_386" ;;
    amd64) asset_hash="$THREEXUI_ASSET_SHA256_AMD64" ;;
    arm64) asset_hash="$THREEXUI_ASSET_SHA256_ARM64" ;;
    armv5) asset_hash="$THREEXUI_ASSET_SHA256_ARMV5" ;;
    armv6) asset_hash="$THREEXUI_ASSET_SHA256_ARMV6" ;;
    armv7) asset_hash="$THREEXUI_ASSET_SHA256_ARMV7" ;;
    s390x) asset_hash="$THREEXUI_ASSET_SHA256_S390X" ;;
    *) exit 73 ;;
  esac

  tmp="$(mktemp -d /tmp/pna-3xui-pinned.XXXXXX)"
  trap 'rm -rf -- "$tmp"' EXIT
  installer="$tmp/install.sh"
  upstream_script="$tmp/x-ui.sh"
  archive="$tmp/x-ui-linux-${arch}.tar.gz"

  curl --fail --location --silent --show-error --retry 5 --retry-delay 3 \
    --connect-timeout 15 --max-time 300 --proto '=https' --tlsv1.2 \
    --output "$installer" "$THREEXUI_INSTALLER_URL"
  curl --fail --location --silent --show-error --retry 5 --retry-delay 3 \
    --connect-timeout 15 --max-time 300 --proto '=https' --tlsv1.2 \
    --output "$upstream_script" "$THREEXUI_SCRIPT_URL"
  curl --fail --location --silent --show-error --retry 5 --retry-delay 3 \
    --connect-timeout 15 --speed-limit 1 --speed-time 300 --proto '=https' --tlsv1.2 \
    --output "$archive" "$THREEXUI_ASSET_BASE_URL/x-ui-linux-${arch}.tar.gz"

  pna_sha256_check "$THREEXUI_INSTALLER_SHA256" "$installer" || { echo "PNA_SUPPLY_CHAIN_ERROR=INSTALLER_HASH" >&2; exit 75; }
  pna_sha256_check "$THREEXUI_SCRIPT_SHA256" "$upstream_script" || { echo "PNA_SUPPLY_CHAIN_ERROR=SCRIPT_HASH" >&2; exit 75; }
  pna_sha256_check "$asset_hash" "$archive" || { echo "PNA_SUPPLY_CHAIN_ERROR=ASSET_HASH" >&2; exit 75; }

  # The verified upstream installer normally downloads the release and x-ui.sh
  # itself. Redirect those exact download sites to the verified local files.
  sed -i '/curl .* -o ${xui_folder}-linux-$(arch).tar.gz/c\        cp -- "$PNA_XUI_ARCHIVE" "${xui_folder}-linux-$(arch).tar.gz"' "$installer"
  sed -i '/curl -fLRo "${xui_script_temp}"/c\    cp -- "$PNA_XUI_SCRIPT" "${xui_script_temp}"' "$installer"
  [ "$(grep -cF 'cp -- "$PNA_XUI_ARCHIVE"' "$installer")" -eq 2 ] || { echo "PNA_SUPPLY_CHAIN_ERROR=INSTALLER_PATCH_ARCHIVE" >&2; exit 76; }
  [ "$(grep -cF 'cp -- "$PNA_XUI_SCRIPT"' "$installer")" -eq 1 ] || { echo "PNA_SUPPLY_CHAIN_ERROR=INSTALLER_PATCH_SCRIPT" >&2; exit 76; }
  ! grep -qF 'raw.githubusercontent.com/MHSanaei/3x-ui/main/x-ui.sh' "$installer" || { echo "PNA_SUPPLY_CHAIN_ERROR=UNPINNED_SCRIPT_REMAINS" >&2; exit 76; }

  export PNA_XUI_ARCHIVE="$archive" PNA_XUI_SCRIPT="$upstream_script"
  printf 'PNA_3XUI_PINNED_INSTALL_BEGIN version=%s commit=%s arch=%s\n' "$THREEXUI_VERSION" "$THREEXUI_COMMIT" "$arch"
  bash "$installer" "$THREEXUI_VERSION"
  [ -x /usr/local/x-ui/x-ui ] || { echo "PNA_SUPPLY_CHAIN_ERROR=BINARY_MISSING" >&2; exit 77; }
  systemctl is-active --quiet x-ui || { echo "PNA_SUPPLY_CHAIN_ERROR=SERVICE_INACTIVE" >&2; exit 77; }
  install -d -m 755 /etc/proxy-runbook
  {
    printf 'THREEXUI_VERSION=%s\n' "$THREEXUI_VERSION"
    printf 'THREEXUI_COMMIT=%s\n' "$THREEXUI_COMMIT"
    printf 'THREEXUI_ASSET_ARCH=%s\n' "$arch"
    printf 'THREEXUI_ASSET_SHA256=%s\n' "$asset_hash"
  } | install -m 644 /dev/stdin /etc/proxy-runbook/third-party-versions.env
  printf 'PNA_3XUI_PINNED_INSTALL_OK version=%s commit=%s arch=%s\n' "$THREEXUI_VERSION" "$THREEXUI_COMMIT" "$arch"
)

pna_download_copyparty_pinned() (
  set -Eeuo pipefail
  local toolkit_root="${1:?toolkit root is required}" destination="${2:?destination is required}" tmp actual_size
  command -v curl >/dev/null 2>&1 || { echo "PNA_SUPPLY_CHAIN_ERROR=CURL_MISSING" >&2; exit 74; }
  command -v sha256sum >/dev/null 2>&1 || { echo "PNA_SUPPLY_CHAIN_ERROR=SHA256SUM_MISSING" >&2; exit 74; }
  pna_load_third_party_lock "$toolkit_root"
  tmp="$(mktemp "${destination}.download.XXXXXX")"
  trap 'rm -f -- "$tmp"' EXIT
  curl --fail --location --silent --show-error --retry 5 --retry-delay 3 \
    --connect-timeout 15 --max-time 300 --speed-limit 1 --speed-time 300 \
    --proto '=https' --tlsv1.2 --output "$tmp" "$COPYPARTY_SFX_URL"
  pna_sha256_check "$COPYPARTY_SFX_SHA256" "$tmp" || {
    echo "PNA_SUPPLY_CHAIN_ERROR=COPYPARTY_HASH" >&2
    exit 75
  }
  actual_size="$(wc -c < "$tmp" | tr -d '[:space:]')"
  [ "$actual_size" = "$COPYPARTY_SFX_SIZE" ] || {
    echo "PNA_SUPPLY_CHAIN_ERROR=COPYPARTY_SIZE" >&2
    exit 75
  }
  install -D -o root -g root -m 0755 "$tmp" "$destination"
  printf 'PNA_COPYPARTY_PINNED_DOWNLOAD_OK version=%s sha256=%s\n' "$COPYPARTY_VERSION" "$COPYPARTY_SFX_SHA256"
)
