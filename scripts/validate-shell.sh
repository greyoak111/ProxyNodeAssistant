#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FAILED=0

while IFS= read -r -d '' file; do
  if ! bash -n "$file"; then
    FAILED=1
  fi
done < <(find "$ROOT/runbook/proxy-node-assistant-v1.0.0/linux" -type f -name '*.sh' -print0)

exit "$FAILED"
