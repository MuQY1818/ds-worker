#!/usr/bin/env bash
# Offline tests: no network, no real Claude Code. Run from anywhere: bash tests/run.sh
set -u
root="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
export DS_CONFIG="$tmp/none.env" DS_RUNS_DIR="$tmp/runs" DS_CLAUDE_BIN="$root/tests/fake-claude"
unset DS_BASE_URL DS_AUTH_TOKEN DS_MODEL DS_RULES_FILE

pass=0; fail=0
check() {  # check <description> <command...>
  local desc="$1"; shift
  if "$@" > "$tmp/out" 2>&1; then
    pass=$((pass + 1)); printf 'ok    %s\n' "$desc"
  else
    fail=$((fail + 1)); printf 'FAIL  %s\n' "$desc"; sed 's/^/      /' "$tmp/out"
  fi
}
contains() { grep -q -- "$2" "$1"; }

# --- inbox hook -------------------------------------------------------------
hook="$root/libexec/ds-inbox-hook"
inbox="$tmp/inbox.md"

check "hook is silent when the inbox is empty" \
  bash -c "out=\$(echo '{}' | DS_INBOX='$inbox' '$hook' PostToolUse); [ -z \"\$out\" ]"

printf 'switch to plan B\n' > "$inbox"
check "hook delivers a PostToolUse message and clears the inbox" \
  bash -c "echo '{}' | DS_INBOX='$inbox' DS_INBOX_LOG='$tmp/inbox.log' '$hook' PostToolUse > '$tmp/h1' \
    && python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert \"plan B\" in d[\"hookSpecificOutput\"][\"additionalContext\"]' '$tmp/h1' \
    && [ ! -e '$inbox' ] && grep -q 'plan B' '$tmp/inbox.log'"

printf 'one more thing\n' > "$inbox"
check "hook blocks Stop while a message is waiting" \
  bash -c "echo '{}' | DS_INBOX='$inbox' '$hook' Stop > '$tmp/h2' \
    && python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d[\"decision\"]==\"block\" and \"one more\" in d[\"reason\"]' '$tmp/h2'"

check "hook header can be customised" \
  bash -c "printf 'hi\n' > '$inbox'; echo '{}' | DS_INBOX='$inbox' DS_INBOX_HEADER='[boss]' '$hook' PostToolUse | grep -q '\\[boss\\]'"

# --- ds argument handling ---------------------------------------------------
printf '# demo task\nSay hello.\n' > "$tmp/demo.md"
check "ds rejects a missing task sheet" bash -c "! '$root/bin/ds' '$tmp/nope.md' '$tmp/r.md'"
check "ds rejects a bad --effort" bash -c "! '$root/bin/ds' '$tmp/demo.md' '$tmp/r.md' --effort max"
check "ds requires a token with a custom endpoint" \
  bash -c "! DS_BASE_URL=http://x '$root/bin/ds' '$tmp/demo.md' '$tmp/r.md'"

# --- end to end with the fake CLI -------------------------------------------
check "ds runs a worker and prints a summary" bash -c "'$root/bin/ds' '$tmp/demo.md' '$tmp/r.md' > '$tmp/e1'"
check "summary reports success" contains "$tmp/e1" "demo.*: done"
check "run files are written" bash -c "ls '$DS_RUNS_DIR'/demo.*.jsonl '$DS_RUNS_DIR'/demo.*.exit '$DS_RUNS_DIR'/demo.*.meta"
check "no pid file is left behind" bash -c "! ls '$DS_RUNS_DIR'/demo.*.pid 2>/dev/null"

check "ds-say queues a message (with a warning when no worker runs)" \
  bash -c "'$root/bin/ds-say' demo 'use the staging database' 2> '$tmp/warn' && grep -q 'no running worker' '$tmp/warn' \
    && grep -q staging '$DS_RUNS_DIR/inbox/demo.md'"
rm -f "$DS_RUNS_DIR/inbox/demo.md"

# A background worker that waits until we have queued a message.
check "ds --bg returns at once" bash -c "FAKE_CLAUDE_WAIT_FOR='$tmp/go' '$root/bin/ds' '$tmp/demo.md' '$tmp/r.md' --bg --name bgdemo > '$tmp/bg'"
check "background worker shows up as running" bash -c "sleep 1; '$root/bin/ds-status' | grep -q 'bgdemo.*running'"
check "ds-say reaches the background worker" \
  bash -c "'$root/bin/ds-say' bgdemo 'stop after step 2' && touch '$tmp/go' && for i in \$(seq 1 50); do ls '$DS_RUNS_DIR'/bgdemo.*.exit >/dev/null 2>&1 && break; sleep 0.1; done; grep -q 'stop after step 2' '$DS_RUNS_DIR'/bgdemo.*.jsonl"
check "ds-status show lists the delivered message" bash -c "'$root/bin/ds-status' bgdemo | grep -q 'stop after step 2'"
check "ds-status show renders tool calls" bash -c "'$root/bin/ds-status' bgdemo | grep -q 'tool  Bash: echo hello'"
check "ds-status list shows finished runs" bash -c "'$root/bin/ds-status' | grep -q 'bgdemo.*done'"

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
