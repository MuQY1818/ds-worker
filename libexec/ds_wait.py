#!/usr/bin/env python3
"""Wait for a ds worker to go idle or exit, then print its report state and usage.

A background session is recorded in <run>.native and tracked through
`claude agents --json`; a foreground or detached `claude -p` worker is tracked
through its .pid file. Either way the walk of the run ends with the same three
lines: what state it is in, which report it left and how big it is, and what the
last thing it said was.
"""
import argparse
import glob
import json
import os
import subprocess
import sys
import time

USAGE_KEYS = ("input_tokens", "output_tokens",
              "cache_read_input_tokens", "cache_creation_input_tokens")


def runs_of(runs, name, ext):
    """(mtime, run id) for every <name>.*<ext> run file."""
    out = []
    for path in glob.glob(os.path.join(runs, name + ".*" + ext)):
        out.append((os.path.getmtime(path), os.path.basename(path)[: -len(ext)]))
    return out


def find_run(runs, name):
    """The newest run for this worker: (run id, 'native' or 'meta')."""
    found = runs_of(runs, name, ".native") + runs_of(runs, name, ".meta")
    if not found:
        return None, None
    rid = max(found)[1]
    native = os.path.exists(os.path.join(runs, rid + ".native"))
    return rid, ("native" if native else "meta")


def agents(claude):
    try:
        done = subprocess.run([claude, "agents", "--json"],
                              capture_output=True, text=True, timeout=120)
        return json.loads(done.stdout or "[]")
    except (OSError, ValueError, subprocess.SubprocessError):
        return None


def native_state(record, claude):
    """busy / idle / gone, or unknown when `claude agents` cannot be read."""
    listed = agents(claude)
    if listed is None:
        return "unknown"
    for a in listed:
        if a.get("sessionId") == record.get("sessionId") or (
                record.get("id") and a.get("id") == record.get("id")):
            return "busy" if a.get("status") == "busy" else "idle"
    return "gone"


def wait_native(record, claude, poll, limit):
    elapsed = 0.0
    seen_busy = False
    misses = 0
    while True:
        state = native_state(record, claude)
        misses = misses + 1 if state == "unknown" else 0
        if misses >= 3:
            return "unknown"
        if state == "busy":
            seen_busy = True
        if state == "gone":
            return "exited"
        # A session is idle for a moment right after it starts; wait for one
        # busy round (or two polls) before believing it finished.
        if state == "idle" and (seen_busy or elapsed >= 2 * poll):
            return "idle"
        if elapsed >= limit:
            return "running"
        time.sleep(poll)
        elapsed += poll


def pid_alive(path):
    try:
        with open(path) as f:
            pid = int(f.read().strip())
    except (OSError, ValueError):
        return False
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        pass
    return True


def wait_pid(runs, rid, poll, limit):
    pid_file = os.path.join(runs, rid + ".pid")
    elapsed = 0.0
    seen_busy = False
    while True:
        alive = pid_alive(pid_file)
        if alive:
            seen_busy = True
        if not alive and (seen_busy or elapsed >= 2 * poll):
            return "exited"
        if elapsed >= limit:
            return "running"
        time.sleep(poll)
        elapsed += poll


def claude_dir():
    return os.environ.get("CLAUDE_CONFIG_DIR") or os.path.expanduser("~/.claude")


def transcript_for(session):
    if not session:
        return None
    hits = sorted(glob.glob(os.path.join(claude_dir(), "projects", "*", session + ".jsonl")))
    return hits[0] if hits else None


def usage(path):
    totals = dict.fromkeys(USAGE_KEYS, 0)
    turns = 0
    last = ""
    try:
        f = open(path, encoding="utf-8", errors="replace")
    except (OSError, TypeError):
        return totals, turns, last
    with f:
        for line in f:
            try:
                event = json.loads(line)
            except ValueError:
                continue
            if event.get("type") != "assistant":
                continue
            message = event.get("message") or {}
            turns += 1
            got = message.get("usage") or {}
            for key in USAGE_KEYS:
                totals[key] += got.get(key) or 0
            for part in message.get("content") or []:
                if isinstance(part, dict) and part.get("type") == "text":
                    text = (part.get("text") or "").strip()
                    if text:
                        last = text
    return totals, turns, last


def report_line(path):
    if not path:
        return "-", "no report recorded"
    if not os.path.exists(path):
        return path, "missing"
    return path, "%d bytes" % os.path.getsize(path)


def main():
    ap = argparse.ArgumentParser(prog="ds-wait")
    ap.add_argument("--runs", required=True)
    ap.add_argument("--claude", default=os.environ.get("DS_CLAUDE_BIN") or "claude")
    ap.add_argument("--poll", type=float, default=30.0, help="seconds between checks")
    ap.add_argument("--max", type=float, default=86400.0, help="give up waiting after this")
    ap.add_argument("name")
    a = ap.parse_args()

    rid, kind = find_run(a.runs, a.name)
    if rid is None:
        sys.exit("ds-wait: no run for %s in %s" % (a.name, a.runs))

    if kind == "native":
        with open(os.path.join(a.runs, rid + ".native"), encoding="utf-8") as f:
            record = json.load(f)
        state = wait_native(record, a.claude, a.poll, a.max)
        ident = record.get("id") or str(record.get("sessionId") or "")[:8] or rid
        report = record.get("report") or ""
        transcript = transcript_for(record.get("sessionId"))
    else:
        fields = open(os.path.join(a.runs, rid + ".meta"), encoding="utf-8").read()
        fields = fields.rstrip("\n").split("\t")
        report = fields[2] if len(fields) > 2 else ""
        state = wait_pid(a.runs, rid, a.poll, a.max)
        ident = rid
        transcript = os.path.join(a.runs, rid + ".jsonl")

    shown = {"running": "still running after %ss" % int(a.max),
             "unknown": "state unknown (claude agents unreadable)"}.get(state, state)
    path, size = report_line(report)
    print("%s (%s): %s; report %s (%s)" % (a.name, ident, shown, path, size))
    totals, turns, last = usage(transcript)
    print("usage  " + " ".join(
        "%s=%d" % (k.replace("_input_tokens", "").replace("_tokens", ""), v)
        for k, v in totals.items()) + " turns=%d" % turns)
    print("last   " + (last[:800] if last else "(nothing yet)"))


if __name__ == "__main__":
    main()
