#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE="$ROOT/runbook/proxy-node-assistant-v1.0.0/linux/23-ss2022-tcp.sh"
[ -r "$SOURCE" ] || { printf 'missing SS2022 runbook: %s\n' "$SOURCE" >&2; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT
mkdir -p "$TMP/bin"
STATE_FILE="$TMP/ufw-state"
DELETE_COUNT="$TMP/delete-count"
MODE_FILE="$TMP/ufw-mode"
printf 'present\n' > "$STATE_FILE"
printf '0\n' > "$DELETE_COUNT"
printf 'normal\n' > "$MODE_FILE"

# Only the tiny UFW surface used by remove_trial_ufw_rules is emulated.  The
# first status call exposes one legacy trial rule; deleting it makes the next
# status call intentionally return no match.  Under `set -o pipefail`, that
# no-match grep is the regression which previously aborted the parent install.
cat > "$TMP/bin/ufw" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
state_file="${PNA_TEST_UFW_STATE:?}"
delete_count="${PNA_TEST_UFW_DELETE_COUNT:?}"
mode_file="${PNA_TEST_UFW_MODE:?}"
case "${1:-}" in
  status)
    if [ "$(<"$mode_file")" = status-fail ]; then
      printf 'simulated UFW status failure\n' >&2
      exit 7
    fi
    if [ "$(<"$state_file")" = present ]; then
      printf '[ 1] 32443/tcp             ALLOW IN    112.22.55.164          # tna-ss2022-112-trial\n'
    else
      printf 'Status: active\n'
    fi
    ;;
  delete)
    [ "${2:-}" = 1 ] || exit 2
    # Real `ufw delete` consumes one confirmation line.
    IFS= read -r _ || true
    if [ "$(<"$mode_file")" = delete-fail ]; then
      exit 8
    fi
    count="$(<"$delete_count")"
    printf '%s\n' "$((count + 1))" > "$delete_count"
    printf 'absent\n' > "$state_file"
    ;;
  *)
    printf 'unexpected ufw invocation: %s\n' "$*" >&2
    exit 2
    ;;
esac
EOF
chmod 700 "$TMP/bin/ufw"

# Extract just the function so this regression never invokes real systemd,
# iptables, or UFW.  The function's closing brace is the only unindented `}`
# in its body; strip CR defensively for a checkout with CRLF shell files.
function_source="$(awk '
  /^remove_trial_ufw_rules\(\) \{/ { inside=1 }
  inside {
    sub(/\r$/, "")
    print
    if ($0 == "}") exit
  }
' "$SOURCE")"
[ -n "$function_source" ] || { echo 'remove_trial_ufw_rules function not found' >&2; exit 1; }

run_cleanup() {
  local stdout="$1" stderr="$2" rc
  set +e
  (
    set -Eeuo pipefail
    export PATH="$TMP/bin:$PATH"
    export PNA_TEST_UFW_STATE="$STATE_FILE"
    export PNA_TEST_UFW_DELETE_COUNT="$DELETE_COUNT"
    export PNA_TEST_UFW_MODE="$MODE_FILE"
    eval "$function_source"
    remove_trial_ufw_rules
  ) >"$stdout" 2>"$stderr"
  rc=$?
  set -e
  return "$rc"
}

if run_cleanup "$TMP/first.out" "$TMP/first.err"; then
  :
else
  rc=$?
  printf 'trial cleanup unexpectedly failed on final-rule removal (rc=%s)\n' "$rc" >&2
  cat "$TMP/first.err" >&2 || true
  exit 1
fi

[ "$(<"$STATE_FILE")" = absent ] || { echo 'fake UFW trial rule was not removed' >&2; exit 1; }
[ "$(<"$DELETE_COUNT")" = 1 ] || { echo 'fake UFW delete was not called exactly once' >&2; exit 1; }
grep -Fxq 'PNA_SS2022_TRIAL_CLEANUP_OK=1' "$TMP/first.out" || {
  echo 'successful trial cleanup marker is missing' >&2
  cat "$TMP/first.out" >&2 || true
  exit 1
}

# A second idempotent invocation starts with no matching rule.  This is the
# exact empty-grep case that must remain a successful no-op.
if run_cleanup "$TMP/second.out" "$TMP/second.err"; then
  :
else
  rc=$?
  printf 'trial cleanup unexpectedly failed when already clean (rc=%s)\n' "$rc" >&2
  cat "$TMP/second.err" >&2 || true
  exit 1
fi
[ "$(<"$DELETE_COUNT")" = 1 ] || { echo 'idempotent cleanup attempted an extra delete' >&2; exit 1; }
grep -Fxq 'PNA_SS2022_TRIAL_CLEANUP_OK=1' "$TMP/second.out" || {
  echo 'idempotent cleanup marker is missing' >&2
  cat "$TMP/second.out" >&2 || true
  exit 1
}

# A real UFW failure is non-fatal after the formal listener is verified: the
# cleanup must emit a warning and return zero so the outer transaction does not
# roll back healthy SS2022 state merely because a legacy rule could not be
# queried.  This also guards the explicit warning contract used by diagnostics.
printf 'present\n' > "$STATE_FILE"
printf 'status-fail\n' > "$MODE_FILE"
if run_cleanup "$TMP/warn.out" "$TMP/warn.err"; then
  :
else
  rc=$?
  printf 'trial cleanup warning path returned non-zero (rc=%s)\n' "$rc" >&2
  cat "$TMP/warn.err" >&2 || true
  exit 1
fi
grep -Fxq 'PNA_SS2022_TRIAL_CLEANUP_WARN=ufw_status_failed' "$TMP/warn.err" || {
  echo 'UFW failure warning marker is missing' >&2
  cat "$TMP/warn.err" >&2 || true
  exit 1
}
[ "$(<"$STATE_FILE")" = present ] || { echo 'UFW status failure unexpectedly removed the trial rule' >&2; exit 1; }
[ "$(<"$DELETE_COUNT")" = 1 ] || { echo 'UFW status failure unexpectedly attempted a delete' >&2; exit 1; }

echo SS2022_TRIAL_CLEANUP_TEST_OK
