#!/usr/bin/env bash
set -Eeuo pipefail

# Offline jq fixture for the global 3x-ui client retirement boundary.  The
# production helper talks to /panel/api/clients/list and deletes only rows
# carrying the tna-/pna-device marker.  This fixture intentionally exercises
# the same partition, subset, and ordinary-identity checks without contacting
# a VPS or touching a real x-ui database.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/runbook/proxy-node-assistant-v1.0.0/linux/00c-retire-v095-device-drive.sh"
command -v jq >/dev/null 2>&1 || {
  printf 'GLOBAL_CLIENT_FIXTURE_SKIPPED_JQ_MISSING\n'
  exit 0
}
command -v comm >/dev/null 2>&1 || {
  printf 'GLOBAL_CLIENT_FIXTURE_SKIPPED_COMM_MISSING\n'
  exit 0
}

TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT
ORIGINAL="$TMP/original.json"
CURRENT="$TMP/current.json"
FOREIGN="$TMP/foreign.json"
MUTATED="$TMP/mutated.json"
FINAL="$TMP/final.json"
ORIGINAL_EMAILS="$TMP/original-emails.txt"
CURRENT_EMAILS="$TMP/current-emails.txt"
ORIGINAL_IDENTITY="$TMP/original-ordinary.json"
CURRENT_IDENTITY="$TMP/current-ordinary.json"
FINAL_IDENTITY="$TMP/final-ordinary.json"

cat > "$ORIGINAL" <<'EOF'
{
  "success": true,
  "obj": [
    {
      "id": 101,
      "email": "ordinary@example.invalid",
      "comment": "customer-owned",
      "inboundIds": [1],
      "up": 123,
      "down": 456
    },
    {
      "id": 202,
      "email": "tna-device:phone-a",
      "comment": "legacy-device",
      "inboundIds": [1],
      "up": 10,
      "down": 20
    },
    {
      "id": 303,
      "email": "ordinary-comment@example.invalid",
      "comment": "pna-device:tablet-b",
      "inboundIds": [2],
      "up": 30,
      "down": 40
    },
    {
      "id": 404,
      "email": "pna-device:orphan",
      "comment": "",
      "inboundIds": [],
      "up": 50,
      "down": 60
    }
  ]
}
EOF

# The fixture has three managed rows (including an orphan not attached to an
# inbound) and one ordinary row.  Mutable traffic counters are deliberately
# present to demonstrate that ordinary identity compares only stable fields.
jq -e '.success == true and (.obj | type == "array") and all(.obj[]; type == "object")' "$ORIGINAL" >/dev/null
[ "$(jq '
  def is_managed:
    (((.comment // "") | if type == "string" then test("^(tna|pna)-device:") else false end) or
     ((.email // "") | if type == "string" then test("^(tna|pna)-device:") else false end));
  [.obj[] | select(is_managed)] | length
' "$ORIGINAL")" -eq 3 ]
[ "$(jq '
  def is_managed:
    (((.comment // "") | if type == "string" then test("^(tna|pna)-device:") else false end) or
     ((.email // "") | if type == "string" then test("^(tna|pna)-device:") else false end));
  [.obj[] | select(is_managed | not)] | length
' "$ORIGINAL")" -eq 1 ]

jq -r '
  def is_managed:
    (((.comment // "") | if type == "string" then test("^(tna|pna)-device:") else false end) or
     ((.email // "") | if type == "string" then test("^(tna|pna)-device:") else false end));
  [.obj[] | select(is_managed) | .email] | sort
' "$ORIGINAL" | sed '/^null$/d' > "$ORIGINAL_EMAILS"
[ "$(wc -l < "$ORIGINAL_EMAILS")" -eq 3 ]

jq -S -c '
  def is_managed:
    (((.comment // "") | if type == "string" then test("^(tna|pna)-device:") else false end) or
     ((.email // "") | if type == "string" then test("^(tna|pna)-device:") else false end));
  [.obj[] | select(is_managed | not) |
    {email:(if (.email | type) == "string" then .email else "" end),
     id:(.id // 0),
     inboundIds:(if (.inboundIds | type) == "array" then .inboundIds else [] end)}] |
    sort_by(.email, .id)
' "$ORIGINAL" > "$ORIGINAL_IDENTITY"

# A nested inbound update may already remove one managed global row.  The
# pre-delete guard must accept that strict subset while preserving ordinary
# identity exactly.
jq ' .obj |= map(select(.email != "pna-device:orphan"))' "$ORIGINAL" > "$CURRENT"
jq -r '
  def is_managed:
    (((.comment // "") | if type == "string" then test("^(tna|pna)-device:") else false end) or
     ((.email // "") | if type == "string" then test("^(tna|pna)-device:") else false end));
  [.obj[] | select(is_managed) | .email] | sort | .[]
' "$CURRENT" > "$CURRENT_EMAILS"
[ -z "$(comm -23 "$CURRENT_EMAILS" "$ORIGINAL_EMAILS")" ]
jq -S -c '
  def is_managed:
    (((.comment // "") | if type == "string" then test("^(tna|pna)-device:") else false end) or
     ((.email // "") | if type == "string" then test("^(tna|pna)-device:") else false end));
  [.obj[] | select(is_managed | not) |
    {email:(if (.email | type) == "string" then .email else "" end),
     id:(.id // 0),
     inboundIds:(if (.inboundIds | type) == "array" then .inboundIds else [] end)}] |
    sort_by(.email, .id)
' "$CURRENT" > "$CURRENT_IDENTITY"
cmp -s -- "$ORIGINAL_IDENTITY" "$CURRENT_IDENTITY"

# A newly-created managed row is not in the original set and must stop the
# operation before any delete request is sent.
jq '.obj += [{"id":505,"email":"pna-device:foreign","comment":"","inboundIds":[]}]' "$CURRENT" > "$FOREIGN"
jq -r '
  def is_managed:
    (((.comment // "") | if type == "string" then test("^(tna|pna)-device:") else false end) or
     ((.email // "") | if type == "string" then test("^(tna|pna)-device:") else false end));
  [.obj[] | select(is_managed) | .email] | sort | .[]
' "$FOREIGN" > "$TMP/foreign-emails.txt"
[ -n "$(comm -23 "$TMP/foreign-emails.txt" "$ORIGINAL_EMAILS")" ]

# Ordinary rows are protected even if an unrelated mutable field changes.
jq ' .obj |= map(if .id == 101 then .up = 999 else . end)' "$CURRENT" > "$MUTATED"
jq -S -c '
  def is_managed:
    (((.comment // "") | if type == "string" then test("^(tna|pna)-device:") else false end) or
     ((.email // "") | if type == "string" then test("^(tna|pna)-device:") else false end));
  [.obj[] | select(is_managed | not) |
    {email:(if (.email | type) == "string" then .email else "" end),
     id:(.id // 0),
     inboundIds:(if (.inboundIds | type) == "array" then .inboundIds else [] end)}] |
    sort_by(.email, .id)
' "$MUTATED" > "$TMP/mutated-identity.json"
cmp -s -- "$ORIGINAL_IDENTITY" "$TMP/mutated-identity.json"

# The final read-back requires no managed rows and the same ordinary identity.
jq '
  def is_managed:
    (((.comment // "") | if type == "string" then test("^(tna|pna)-device:") else false end) or
     ((.email // "") | if type == "string" then test("^(tna|pna)-device:") else false end));
  .obj |= map(select(is_managed | not))
' "$ORIGINAL" > "$FINAL"
[ "$(jq '
  def is_managed:
    (((.comment // "") | if type == "string" then test("^(tna|pna)-device:") else false end) or
     ((.email // "") | if type == "string" then test("^(tna|pna)-device:") else false end));
  [.obj[] | select(is_managed)] | length
' "$FINAL")" -eq 0 ]
jq -S -c '
  def is_managed:
    (((.comment // "") | if type == "string" then test("^(tna|pna)-device:") else false end) or
     ((.email // "") | if type == "string" then test("^(tna|pna)-device:") else false end));
  [.obj[] | select(is_managed | not) |
    {email:(if (.email | type) == "string" then .email else "" end),
     id:(.id // 0),
     inboundIds:(if (.inboundIds | type) == "array" then .inboundIds else [] end)}] |
    sort_by(.email, .id)
' "$FINAL" > "$FINAL_IDENTITY"
cmp -s -- "$ORIGINAL_IDENTITY" "$FINAL_IDENTITY"

# Duplicate and control-character emails are rejected rather than allowing an
# ambiguous or line-injecting delete target.
jq '.obj[1].email = "pna-device:orphan"' "$ORIGINAL" > "$TMP/duplicate.json"
[ "$(jq '
  def is_managed:
    (((.comment // "") | if type == "string" then test("^(tna|pna)-device:") else false end) or
     ((.email // "") | if type == "string" then test("^(tna|pna)-device:") else false end));
  [.obj[] | select(is_managed) | .email] | group_by(.) | map(select(length > 1)) | length
' "$TMP/duplicate.json")" -gt 0 ]
jq '.obj[1].email = "pna-device:bad\nvalue"' "$ORIGINAL" > "$TMP/control.json"
[ "$(jq '
  def is_managed:
    (((.comment // "") | if type == "string" then test("^(tna|pna)-device:") else false end) or
     ((.email // "") | if type == "string" then test("^(tna|pna)-device:") else false end));
  [.obj[] | select(is_managed) |
    select((.email | type) != "string" or (.email | length) == 0 or (.email | test("[\\r\\n\\t]")))] | length
' "$TMP/control.json")" -gt 0 ]

# URL escaping must happen in jq, not through shell interpolation.
[ "$(jq -nr --arg email 'pna-device/a?b' '$email | @uri')" = 'pna-device%2Fa%3Fb' ]

# Keep this test tied to the production source so a future refactor cannot
# silently remove the endpoint or the final ordinary-client guard.
grep -Fq '/panel/api/clients/list' "$SCRIPT"
grep -Fq '/panel/api/clients/del/' "$SCRIPT"
grep -Fq 'XUI_GLOBAL_UNMANAGED_READBACK_MISMATCH' "$SCRIPT"

printf 'GLOBAL_CLIENT_FIXTURE_TEST_OK\n'
