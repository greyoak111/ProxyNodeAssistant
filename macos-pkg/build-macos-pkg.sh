#!/bin/zsh
# Compatibility entry point. The old script built a system-wide Terminal
# wrapper and left global CLI files behind. Keep the familiar command name,
# but route it to the native user-level GUI package instead.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
exec "$ROOT/macos-pkg/build-macos-gui-pkg.sh" "$@"
