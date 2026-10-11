#!/usr/bin/env bash
# Shared paths, logging, and resume state.

if [[ -z "${AI_DATA_DIR:-}" ]]; then
  AI_DATA_DIR="/var/lib/ai-ready"
fi

# Consumed by setup.sh and the install libraries after this file is sourced.
# shellcheck disable=SC2034
AI_STATE_FILE="${AI_DATA_DIR}/state"
# shellcheck disable=SC2034
AI_LOG_FILE="/var/log/ai-ready-setup.log"
# shellcheck disable=SC2034
AI_ENV_FILE="/etc/ai-ready/env"
# shellcheck disable=SC2034
AI_WEBUI_ENV_FILE="/etc/ai-ready/openwebui.env"

log() {
  printf '%s\n' "$*"
}

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

state_has() {
  local key="$1"
  [[ -f "$AI_STATE_FILE" ]] && grep -qx -- "$key" "$AI_STATE_FILE"
}

state_add() {
  local key="$1"
  mkdir -p "$(dirname "$AI_STATE_FILE")"
  if ! state_has "$key"; then
    printf '%s\n' "$key" >>"$AI_STATE_FILE"
  fi
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}
