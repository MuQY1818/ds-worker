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

# The claude CLI to talk to; the tests point DS_CLAUDE_BIN at a stand-in.
ds_claude() {
  "${DS_CLAUDE_BIN:-claude}" "$@"
}

# Is a worker of this name running? A foreground or detached `claude -p` run has
# a live .pid file; a background session is listed by `claude agents`.
ds_worker_running() {
  local name="$1" p
  for p in "$DS_RUNS_DIR/$name".*.pid; do
    [ -f "$p" ] || continue
    kill -0 "$(cat "$p")" 2>/dev/null && return 0
  done
  for p in "$DS_RUNS_DIR/$name".*.native; do
    [ -f "$p" ] || continue
    ds_claude agents --json 2>/dev/null | python3 -c 'import json, sys
name = sys.argv[1]
try:
    agents = json.load(sys.stdin)
except ValueError:
    agents = []
sys.exit(0 if any(a.get("name") == name and a.get("kind") == "background" for a in agents) else 1)' "$name" && return 0
  done
  return 1
}
