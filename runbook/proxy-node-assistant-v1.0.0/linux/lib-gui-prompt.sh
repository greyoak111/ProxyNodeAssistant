#!/usr/bin/env bash

# A remote read -p prompt has no trailing newline. That is fine in a terminal,
# but a graphical wrapper reading line-by-line cannot see it and deadlocks.
# GUI mode emits the same base64 line protocol used by the Windows core.
proxy_runbook_read_answer() {
  local prompt="$1" payload answer=""
  if [ "${PROXY_RUNBOOK_GUI_MODE:-0}" = "1" ]; then
    payload="$(printf '%s' "$prompt" | base64 | tr -d '\r\n')"
    # stderr keeps the frame outside command substitution, just like read -p.
    printf 'PNA_GUI_PROMPT_B64=%s\n' "$payload" >&2
    IFS= read -r answer || return 1
  else
    IFS= read -r -p "$prompt: " answer || return 1
  fi
  printf '%s' "$answer"
}
