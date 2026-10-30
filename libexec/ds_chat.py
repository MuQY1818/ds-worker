#!/usr/bin/env python3
"""Condense the last N messages of a Claude Code transcript into a context file.

`ds --chat N` writes this into the worker's context so a task sheet can start
from "what we were just doing" without pasting the conversation by hand. By
default the newest transcript under ~/.claude/projects is used (CLAUDE_CONFIG_DIR
is honoured, as it is by Claude Code itself).

Tool results, side-chain (subagent) turns, meta messages and compaction summaries
are skipped: they are noise for a worker that only needs the decisions.
"""
import argparse
import glob
import json
import os
import sys

TURN_LIMIT = 4000          # characters kept per message


def claude_dir():
    return os.environ.get("CLAUDE_CONFIG_DIR") or os.path.expanduser("~/.claude")


def newest_transcript():
    files = glob.glob(os.path.join(claude_dir(), "projects", "*", "*.jsonl"))
    if not files:
        sys.exit("ds_chat: no transcript under " + os.path.join(claude_dir(), "projects"))
    return max(files, key=os.path.getmtime)


def turns(path):
    with open(path, encoding="utf-8", errors="replace") as f:
        for line in f:
            try:
                event = json.loads(line)
            except ValueError:
                continue
            kind = event.get("type")
            if kind not in ("user", "assistant"):
                continue
            if event.get("isSidechain") or event.get("isMeta") or event.get("isCompactSummary"):
                continue
            text = (event.get("message") or {}).get("content")
            if isinstance(text, list):
                text = "\n".join(part.get("text", "") for part in text
                                 if isinstance(part, dict) and part.get("type") == "text")
            text = (text or "").strip()
            if not text or text.startswith("<"):
                continue          # tool results, system reminders, command echoes
            yield ("User" if kind == "user" else "Assistant", text[:TURN_LIMIT])


def main():
    ap = argparse.ArgumentParser(prog="ds_chat")
    ap.add_argument("--from", dest="source", default="",
                    help="transcript to read (default: the newest one)")
    ap.add_argument("--turns", type=int, default=0, help="how many messages to keep")
    a = ap.parse_args()
    if a.turns < 1:
        sys.exit("ds_chat: --turns must be at least 1")
    src = a.source or newest_transcript()
    if not os.path.isfile(src):
        sys.exit("ds_chat: no such transcript: " + src)
    kept = list(turns(src))[-a.turns:]
    if not kept:
        print("ds_chat: no user or assistant messages in " + src, file=sys.stderr)
    print("# Recent dispatcher conversation (from %s)\n" % src)
    for who, text in kept:
        print("## %s\n\n%s\n" % (who, text))


if __name__ == "__main__":
    main()
