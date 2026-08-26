#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

STATE_ROOT=/var/lib/text-node-assistant/migrations
JOURNAL="$STATE_ROOT/pna-to-tna-v1.env"

[ "$(id -u)" -eq 0 ] || { echo 'TNA_MIGRATION_ERROR=ROOT_REQUIRED' >&2; exit 64; }
install -d -m 700 "$STATE_ROOT"

refuse_link() {
  local path="$1"
  [ ! -L "$path" ] || { printf 'TNA_MIGRATION_ERROR=SYMLINK_REFUSED path=%s\n' "$path" >&2; exit 65; }
}

copy_tree_if_missing() {
  local source="$1" target="$2" label="$3" parent
  [ -e "$source" ] || return 0
  refuse_link "$source"
  refuse_link "$target"
  if [ -e "$target" ]; then
    printf 'MIGRATION_PRESERVED_BOTH=%s\n' "$label"
    return 0
  fi
  parent="$(dirname "$target")"
  refuse_link "$parent"
  if [ -e "$parent" ]; then
    [ -d "$parent" ] || { printf 'TNA_MIGRATION_ERROR=PARENT_NOT_DIRECTORY path=%s\n' "$parent" >&2; exit 65; }
  else
    install -d -m 700 "$parent"
  fi
  cp -a -- "$source" "$target.tmp.$$"
  mv -- "$target.tmp.$$" "$target"
  printf 'MIGRATION_COPIED=%s\n' "$label"
}

if [ -s "$JOURNAL" ] && grep -Fqx 'MIGRATION_STATUS=COMMITTED' "$JOURNAL"; then
  echo 'TNA_LEGACY_MIGRATION_ALREADY_COMMITTED'
  exit 0
fi

tmp="$JOURNAL.tmp.$$"
{
  echo 'MIGRATION_SCHEMA=1'
  echo 'MIGRATION_STATUS=RUNNING'
  printf 'STARTED_AT=%s\n' "$(date -Is)"
} > "$tmp"
chmod 600 "$tmp"
mv -f -- "$tmp" "$JOURNAL"

copy_tree_if_missing /etc/proxy-runbook /etc/text-node-assistant ETC_STATE | tee -a "$JOURNAL"
copy_tree_if_missing /root/.config/proxy-runbook /root/.config/text-node-assistant ROOT_STATE | tee -a "$JOURNAL"

# The legacy file volume can be large. It is deliberately not copied, moved,
# deleted, or symlinked during toolkit bootstrap. The drive transaction adopts
# that exact directory in place and validates file counts before committing.
if [ -d /srv/proxy-node-assistant/drive-data ] && [ ! -d /srv/text-node-assistant/drive-data ]; then
  refuse_link /srv/proxy-node-assistant/drive-data
  printf 'LEGACY_DRIVE_DATA_DIR=%s\n' /srv/proxy-node-assistant/drive-data | tee -a "$JOURNAL"
fi

{
  echo 'MIGRATION_STATUS=COMMITTED'
  printf 'FINISHED_AT=%s\n' "$(date -Is)"
} >> "$JOURNAL"
chmod 600 "$JOURNAL"
echo 'TNA_LEGACY_MIGRATION_COMMITTED'
