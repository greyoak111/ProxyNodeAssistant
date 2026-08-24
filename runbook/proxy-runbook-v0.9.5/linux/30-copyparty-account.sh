#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DRIVE="$ROOT/linux/29-copyparty-drive.sh"

case "${1:-}" in
  rotate)
    [ "$#" -eq 3 ] || { echo 'usage: 30-copyparty-account.sh rotate USERNAME 2|3' >&2; exit 2; }
    exec bash "$DRIVE" rotate "$2" "$3"
    ;;
  verify)
    [ "$#" -eq 2 ] || { echo 'usage: 30-copyparty-account.sh verify USERNAME' >&2; exit 2; }
    exec bash "$DRIVE" verify "$2"
    ;;
  status)
    [ "$#" -eq 1 ] || exit 2
    exec bash "$DRIVE" status
    ;;
  *) echo 'usage: 30-copyparty-account.sh rotate USERNAME 2|3 | verify USERNAME | status' >&2; exit 2 ;;
esac
