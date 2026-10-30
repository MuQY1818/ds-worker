#!/usr/bin/env bash
# Offline tests: no network, no real Claude Code. Run from anywhere: bash tests/run.sh
set -u
root="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'pkill -f "$root/libexec/ds-watchdog" 2>/dev/null; rm -rf "$tmp"' EXIT
export DS_CONFIG="$tmp/none.env" DS_RUNS_DIR="$tmp/runs" DS_CLAUDE_BIN="$root/tests/fake-claude"
export DS_NATIVE=0                       # background sessions are the default otherwise
export FAKE_CLAUDE_STATE="$tmp/fake-state" CLAUDE_CONFIG_DIR="$tmp/claude"
unset DS_BASE_URL DS_AUTH_TOKEN DS_MODEL DS_RULES_FILE
mkdir -p "$FAKE_CLAUDE_STATE" "$CLAUDE_CONFIG_DIR/projects/-fake"
printf '# demo task\nSay hello.\n' > "$tmp/demo.md"

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

# --- report acceptance (Stop hook) ------------------------------------------
rep="$tmp/report.md"; nag="$tmp/report.nag"
check "hook blocks Stop when the report is missing" \
  bash -c "echo '{}' | DS_REPORT='$rep' DS_REPORT_NAG='$nag' '$hook' Stop > '$tmp/r1' \
    && python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d[\"decision\"]==\"block\" and \"report\" in d[\"reason\"]' '$tmp/r1' \
    && [ \"\$(cat '$nag')\" = 1 ]"
check "hook gives up after two reminders" \
  bash -c "echo '{}' | DS_REPORT='$rep' DS_REPORT_NAG='$nag' '$hook' Stop > '$tmp/r2' && [ -s '$tmp/r2' ] \
    && echo '{}' | DS_REPORT='$rep' DS_REPORT_NAG='$nag' '$hook' Stop > '$tmp/r3' && [ ! -s '$tmp/r3' ] \
    && [ \"\$(cat '$nag')\" = 2 ]"
check "hook accepts a report of 300 bytes" \
  bash -c "python3 -c 'open(\"'$rep'\",\"w\").write(\"x\"*300)' \
    && out=\$(echo '{}' | DS_REPORT='$rep' DS_REPORT_NAG='$nag' '$hook' Stop) && [ -z \"\$out\" ]"
check "hook still blocks a too-short report" \
  bash -c "printf 'short\\n' > '$rep'; out=\$(echo '{}' | DS_REPORT='$rep' DS_REPORT_NAG='$tmp/report2.nag' DS_REPORT_MIN=300 '$hook' Stop); [ -n \"\$out\" ]"

# --- conversation context ---------------------------------------------------
python3 - "$CLAUDE_CONFIG_DIR/projects/-fake/session-old.jsonl" <<'PY'
import json, sys
rows = [
    {"type": "user", "message": {"content": "first question"}},
    {"type": "assistant", "message": {"content": [{"type": "text", "text": "first answer"}]}},
    {"type": "user", "message": {"content": [{"type": "tool_result", "content": "NOISE tool result"}]}},
    {"type": "assistant", "isSidechain": True,
     "message": {"content": [{"type": "text", "text": "NOISE sidechain"}]}},
    {"type": "user", "message": {"content": "second question"}},
    {"type": "assistant", "message": {"content": [{"type": "text", "text": "second answer"}]}},
]
with open(sys.argv[1], "w", encoding="utf-8") as f:
    for row in rows:
        f.write(json.dumps(row) + "\n")
PY
history="$CLAUDE_CONFIG_DIR/projects/-fake/session-old.jsonl"

check "ds_chat keeps the last turns and drops tool results and side chains" \
  bash -c "'$root/libexec/ds_chat.py' --from '$history' --turns 2 > '$tmp/chat.md' \
    && grep -q 'second answer' '$tmp/chat.md' && ! grep -q 'NOISE' '$tmp/chat.md' \
    && ! grep -q 'first answer' '$tmp/chat.md'"
check "ds_chat reads the newest transcript when none is named" \
  bash -c "'$root/libexec/ds_chat.py' --turns 5 > '$tmp/chat2.md' && grep -q 'second answer' '$tmp/chat2.md'"
check "ds --chat hands the worker a context file" \
  bash -c "FAKE_CLAUDE_STDIN='$tmp/stdin1' '$root/bin/ds' '$tmp/demo.md' '$tmp/r-chat.md' --chat 2 --chat-from '$history' > '$tmp/ch' \
    && grep -q 'context.md' '$tmp/stdin1' && grep -q 'second answer' \$(ls -t '$DS_RUNS_DIR'/*.context.md | head -1)"

# --- ds argument handling ---------------------------------------------------
check "ds rejects a missing task sheet" bash -c "! '$root/bin/ds' '$tmp/nope.md' '$tmp/r.md'"
check "ds rejects a bad --effort" bash -c "! '$root/bin/ds' '$tmp/demo.md' '$tmp/r.md' --effort max"
check "ds requires a token with a custom endpoint" \
  bash -c "! DS_BASE_URL=http://x '$root/bin/ds' '$tmp/demo.md' '$tmp/r.md'"
check "ds rejects a missing context file" \
  bash -c "! '$root/bin/ds' '$tmp/demo.md' '$tmp/r.md' --context '$tmp/nope.md'"
check "ds rejects --chat-from without --chat" \
  bash -c "! '$root/bin/ds' '$tmp/demo.md' '$tmp/r.md' --chat-from '$history'"

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

# --- prompt extras ----------------------------------------------------------
printf 'background A\n' > "$tmp/ctxA.md"
check "ds --context names the file in the worker's prompt" \
  bash -c "FAKE_CLAUDE_STDIN='$tmp/stdin2' '$root/bin/ds' '$tmp/demo.md' '$tmp/r-ctx.md' --context '$tmp/ctxA.md' > /dev/null \
    && grep -q 'ctxA.md' '$tmp/stdin2'"
check "ds --ask-to names the session in the rules" \
  bash -c "FAKE_CLAUDE_ARGS='$tmp/args' '$root/bin/ds' '$tmp/demo.md' '$tmp/r-ask.md' --ask-to 'boss session' > /dev/null \
    && grep -q 'boss session' '$tmp/args'"

git init -q "$tmp/origin"
check "ds --clone gives the worker an isolated clone" \
  bash -c "FAKE_CLAUDE_STDIN='$tmp/stdin3' '$root/bin/ds' '$tmp/demo.md' '$tmp/r-clone.md' --clone '$tmp/origin' --name clonetask > /dev/null \
    && [ -d '$DS_RUNS_DIR/clones/clonetask/repo/.git' ] && grep -q 'clones/clonetask/repo' '$tmp/stdin3'"
check "ds refuses to reuse a clone directory" \
  bash -c "! '$root/bin/ds' '$tmp/demo.md' '$tmp/r-clone2.md' --clone '$tmp/origin' --name clonetask"

# --- native background sessions ---------------------------------------------
check "ds --native starts a background session" \
  bash -c "'$root/bin/ds' '$tmp/demo.md' '$tmp/rep-nat.md' --native --name natdemo > '$tmp/nat' \
    && grep -q 'background session' '$tmp/nat' && ls '$DS_RUNS_DIR'/natdemo.*.native > /dev/null"
check "ds-status lists a native worker" bash -c "'$root/bin/ds-status' | grep -q 'natdemo.*running'"
check "ds-status show renders a native worker" bash -c "'$root/bin/ds-status' natdemo | grep -q 'working on it'"
check "ds-say does not warn about a running native worker" \
  bash -c "'$root/bin/ds-say' natdemo 'ping' 2> '$tmp/warn2' && [ ! -s '$tmp/warn2' ]"
check "ds refuses a name that a busy session still uses" \
  bash -c "! '$root/bin/ds' '$tmp/demo.md' '$tmp/r-dup.md' --native --name natdemo"
rm -f "$DS_RUNS_DIR/inbox/natdemo.md"

printf 'x%.0s' $(seq 1 500) > "$tmp/rep-nat.md"
check "ds-wait waits for idle, then prints the report, usage and last message" \
  bash -c "( sleep 0.4; '$root/tests/fake-claude' done natdemo ) & \
    '$root/bin/ds-wait' natdemo --poll 0.2 --max 20 > '$tmp/wait1' \
    && grep -q 'idle' '$tmp/wait1' && grep -q '500 bytes' '$tmp/wait1' \
    && grep -q 'turns=2' '$tmp/wait1' && grep -q 'last   inbox' '$tmp/wait1'"

check "a finished session's name can be used again" \
  bash -c "'$root/bin/ds' '$tmp/demo.md' '$tmp/rep-nat2.md' --native --name natdemo > '$tmp/nat2' \
    && grep -q 'background session' '$tmp/nat2'"

check "ds --native refuses --resume" \
  bash -c "! '$root/bin/ds' '$tmp/demo.md' '$tmp/r.md' --native --resume abc"

check "the watchdog stops a background session at --timeout" \
  bash -c "FAKE_CLAUDE_STOP_LOG='$tmp/stop.log' '$root/bin/ds' '$tmp/demo.md' '$tmp/rep-t.md' --native --name timerdemo --timeout 1 > '$tmp/timer' \
    && for i in \$(seq 1 80); do [ -f '$DS_RUNS_DIR'/timerdemo.*.timeout ] && break; sleep 0.1; done \
    && ls '$DS_RUNS_DIR'/timerdemo.*.timeout > /dev/null && grep -q . '$tmp/stop.log'"
check "a stopped run shows as timeout in ds-status" \
  bash -c "'$root/bin/ds-status' timerdemo | grep -q '\\[timeout\\]'"

cat > "$tmp/check_settings.py" <<'PY'
import glob, json, sys
path = glob.glob(sys.argv[1])[0]
raw = open(path, encoding="utf-8").read()
settings = json.loads(raw)
env = settings["env"]
assert env["ANTHROPIC_BASE_URL"] == "https://api.example.test", env
assert env["ANTHROPIC_MODEL"] == "m1", env
assert settings["apiKeyHelper"].startswith("DS_CONFIG="), settings
assert "sekrit" not in raw, "the token must not be written to the settings file"
assert "DS_REPORT=" in raw and "Stop" in raw, raw
PY
check "native settings carry the endpoint and a key helper, never the token" \
  bash -c "DS_BASE_URL=https://api.example.test DS_AUTH_TOKEN=sekrit '$root/bin/ds' '$tmp/demo.md' '$tmp/rep-s.md' \
    --native --name settdemo --model m1 > '$tmp/sett' \
    && python3 '$tmp/check_settings.py' '$DS_RUNS_DIR/settdemo.*.settings.json'"

printf 'DS_AUTH_TOKEN=hunter2\n' > "$tmp/key.env"
check "the key helper prints the token from the config" \
  bash -c "DS_CONFIG='$tmp/key.env' '$root/libexec/ds-key-helper' > '$tmp/key.out' && [ \"\$(cat '$tmp/key.out')\" = hunter2 ]"
check "the key helper fails without a token" \
  bash -c "! DS_CONFIG='$tmp/absent.env' '$root/libexec/ds-key-helper' 2> /dev/null"

check "a claude with --bg makes native the default" \
  bash -c "env -u DS_NATIVE '$root/bin/ds' '$tmp/demo.md' '$tmp/rep-auto.md' --name autodemo > '$tmp/auto' \
    && grep -q 'background session' '$tmp/auto'"
check "a claude without --bg falls back to the print mode" \
  bash -c "env -u DS_NATIVE FAKE_CLAUDE_NO_BG=1 '$root/bin/ds' '$tmp/demo.md' '$tmp/rep-old.md' --name olddemo > '$tmp/old' \
    && grep -q 'olddemo.*: done' '$tmp/old'"

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
