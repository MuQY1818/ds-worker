# shellcheck shell=bash
# Shared setup for the ds commands: load the user's config and agree on where runs live.
# Sourced after the caller has set DS_HOME.

DS_CONFIG="${DS_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/ds-worker/config.env}"
if [ -f "$DS_CONFIG" ]; then
  set -a
  # shellcheck source=/dev/null
  . "$DS_CONFIG"
  set +a
fi

DS_RUNS_DIR="${DS_RUNS_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/ds-worker/runs}"
# shellcheck disable=SC2034  # used by the scripts that source this file
DS_INBOX_DIR="$DS_RUNS_DIR/inbox"

# Worker name from a task-sheet path: tasks/fix-login.md -> fix-login
ds_name() {
  local n
  n="$(basename "$1")"
  printf '%s\n' "${n%.*}"
}

ds_die() {
  printf '%s: %s\n' "$(basename "$0")" "$*" >&2
  exit 2
}
