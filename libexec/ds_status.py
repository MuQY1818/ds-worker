#!/usr/bin/env python3
"""Inspect ds worker runs: list them, show recent activity, follow a live one.

A run is a set of files in the runs directory sharing a run id
(<name>.<YYYYmmdd-HHMMSS>): .jsonl (Claude Code stream-json output), .err,
.pid (while running), .exit, .meta and .inbox.log (delivered messages).

A background session (`ds --native`) writes .native instead of .jsonl: its
transcript belongs to Claude Code, under ~/.claude/projects, and its state comes
from `claude agents --json`.
"""
import argparse
import json
import os
import subprocess
import sys
import time
from glob import glob

WIDTH = 160
AGENTS = {}


def one_line(text, width=WIDTH):
    text = " ".join(str(text).split())
    return text if len(text) <= width else text[: width - 1] + "…"


def run_ids(runs):
    found = {}
    for ext in (".jsonl", ".native"):
        for p in glob(os.path.join(runs, "*" + ext)):
            rid = os.path.basename(p)[: -len(ext)]
            found[rid] = max(found.get(rid, 0), os.path.getmtime(p))
    return [rid for rid, _ in sorted(found.items(), key=lambda kv: kv[1], reverse=True)]


def native_record(runs, rid):
    try:
        with open(os.path.join(runs, rid + ".native"), encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        return None


def agents(claude):
    """`claude agents --json`, once per process; None when it cannot be read."""
    if claude not in AGENTS:
        try:
            done = subprocess.run([claude, "agents", "--json"],
                                  capture_output=True, text=True, timeout=120)
            AGENTS[claude] = json.loads(done.stdout or "[]")
        except (OSError, ValueError, subprocess.SubprocessError):
            AGENTS[claude] = None
    return AGENTS[claude]


def native_state(record, claude):
    listed = agents(claude)
    if listed is None:
        return "unknown"
    for a in listed:
        if a.get("sessionId") == record.get("sessionId") or (
                record.get("id") and a.get("id") == record.get("id")):
            return "running" if a.get("status") == "busy" else "idle"
    return "exited"


def claude_dir():
    return os.environ.get("CLAUDE_CONFIG_DIR") or os.path.expanduser("~/.claude")


def transcript_for(session):
    if not session:
        return None
    hits = sorted(glob(os.path.join(claude_dir(), "projects", "*", session + ".jsonl")))
    return hits[0] if hits else None


def resolve(runs, ref):
    if ref.endswith(".jsonl") and os.path.isfile(ref):
        return os.path.dirname(os.path.abspath(ref)), os.path.basename(ref)[: -len(".jsonl")]
    ids = run_ids(runs)
    for match in (lambda r: r == ref,
                  lambda r: r.rsplit(".", 1)[0] == ref,
                  lambda r: r.startswith(ref)):
        hits = [r for r in ids if match(r)]
        if hits:
            return runs, hits[0]
    sys.exit(f"ds-status: no run matches {ref!r} in {runs}")


def read_events(path, offset=0):
    """Parse complete JSON lines from offset; return (events, new_offset)."""
    events = []
    try:
        with open(path, "rb") as f:
            f.seek(offset)
            data = f.read()
    except OSError:
        return events, offset
    end = data.rfind(b"\n") + 1          # leave a half-written last line for later
    for line in data[:end].splitlines():
        try:
            events.append(json.loads(line))
        except ValueError:
            pass
    return events, offset + end


def pid_alive(runs, rid):
    try:
        pid = int(open(os.path.join(runs, rid + ".pid")).read())
    except (OSError, ValueError):
        return False
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        pass
    return True


def info(runs, rid, claude="claude"):
    record = native_record(runs, rid)
    if record is not None:
        state = native_state(record, claude)
        if state == "exited" and os.path.exists(os.path.join(runs, rid + ".timeout")):
            state = "timeout"
        transcript = transcript_for(record.get("sessionId"))
        events, _ = read_events(transcript) if transcript else ([], 0)
        tools = sum(1 for e in events if e.get("type") == "assistant"
                    for c in content(e) if c.get("type") == "tool_use")
        return {"state": state, "tools": tools, "result": None,
                "session": record.get("sessionId"), "native": True,
                "record": record, "transcript": transcript}
    events, _ = read_events(os.path.join(runs, rid + ".jsonl"))
    tools = sum(1 for e in events if e.get("type") == "assistant"
                for c in content(e) if c.get("type") == "tool_use")
    results = [e for e in events if e.get("type") == "result"]
    session = next((e.get("session_id") for e in events if e.get("session_id")), None)
    result = results[-1] if results else None
    if pid_alive(runs, rid):
        state = "running"
    else:
        try:
            code = int(open(os.path.join(runs, rid + ".exit")).read())
        except (OSError, ValueError):
            code = None
        if code == 142:                   # SIGALRM from the --timeout guard
            state = "timeout"
        elif result is not None and code in (0, None):
            state = "error" if result.get("is_error") else "done"
        elif code is None:
            state = "stopped"             # killed before ds could record an exit code
        else:
            state = f"failed ({code})"
    return {"state": state, "tools": tools, "result": result, "session": session}


def content(event):
    c = (event.get("message") or {}).get("content")
    return c if isinstance(c, list) else []


def describe_tool(block):
    inp = block.get("input") or {}
    for key in ("command", "file_path", "pattern", "url", "description", "prompt"):
        if inp.get(key):
            return f"{block.get('name')}: {inp[key]}"
    return f"{block.get('name')}: {json.dumps(inp, ensure_ascii=False)}"


def render(event):
    kind = event.get("type")
    lines = []
    if kind == "assistant":
        for c in content(event):
            if c.get("type") == "text" and c.get("text", "").strip():
                lines.append(("say ", c["text"]))
            elif c.get("type") == "tool_use":
                lines.append(("tool", describe_tool(c)))
    elif kind == "user":
        for c in content(event):
            if c.get("type") == "tool_result" and c.get("is_error"):
                body = c.get("content")
                body = body if isinstance(body, str) else json.dumps(body, ensure_ascii=False)
                lines.append(("err ", body))
    elif kind == "result":
        secs = round((event.get("duration_ms") or 0) / 1000)
        verdict = "error" if event.get("is_error") else "done"
        lines.append(("end ", f"{verdict} after {secs}s, {event.get('num_turns')} turns"))
    elif kind == "system" and event.get("subtype") == "status" and event.get("status"):
        lines.append(("sys ", event["status"]))
    return [f"  {tag}  {one_line(text)}" for tag, text in lines]


def inbox_lines(runs, rid):
    out = []
    try:
        for line in open(os.path.join(runs, rid + ".inbox.log"), encoding="utf-8"):
            d = json.loads(line)
            out.append(f"  {d['time'][11:]}  {one_line(d['message'])}")
    except (OSError, ValueError, KeyError):
        pass
    return out


def age(path):
    s = int(time.time() - os.path.getmtime(path))
    for unit, n in (("d", 86400), ("h", 3600), ("m", 60)):
        if s >= n:
            return f"{s // n}{unit} ago"
    return f"{s}s ago"


def cmd_list(runs, show_all, claude="claude"):
    ids = run_ids(runs)
    if not ids:
        print(f"no runs yet in {runs}")
        return
    print(f"{'RUN':<44} {'STATE':<12} {'TOOLS':>5}  UPDATED")
    for rid in ids if show_all else ids[:15]:
        i = info(runs, rid, claude)
        stamp = os.path.join(runs, rid + (".native" if i.get("native") else ".jsonl"))
        print(f"{rid:<44} {i['state']:<12} {i['tools']:>5}  {age(stamp)}")
    if not show_all and len(ids) > 15:
        print(f"... {len(ids) - 15} older runs (ds-status -a)")


def cmd_show(runs, ref, n, follow, claude="claude"):
    runs, rid = resolve(runs, ref)
    i = info(runs, rid, claude)
    msgs = inbox_lines(runs, rid)
    if i.get("native"):
        record = i["record"]
        path = i["transcript"] or os.path.join(runs, rid + ".launch")
        report = record.get("report") or "-"
        try:
            size = f"{os.path.getsize(report)} bytes"
        except (OSError, TypeError):
            size = "missing"
        print(f"{rid}  [{i['state']}]  session {i['session'] or '-'}")
        print(f"  worker {record.get('name')}  report {report} ({size})")
        print(f"  log {path}")
    else:
        path = os.path.join(runs, rid + ".jsonl")
        print(f"{rid}  [{i['state']}]  session {i['session'] or '-'}")
        print(f"  log {path}")
    if msgs:
        print("inbox (delivered):")
        print("\n".join(msgs))
    events, offset = read_events(path)
    lines = [l for e in events for l in render(e)]
    print(f"last {min(n, len(lines))} of {len(lines)} events:")
    print("\n".join(lines[-n:]))
    seen = len(msgs)
    while follow:
        time.sleep(3)
        msgs = inbox_lines(runs, rid)
        for line in msgs[seen:]:
            print(f"  inbox{line[1:]}", flush=True)
        seen = len(msgs)
        events, offset = read_events(path, offset)
        for e in events:
            for line in render(e):
                print(line, flush=True)
        if i.get("native"):
            state = native_state(i["record"], claude)
            if state in ("exited", "timeout"):
                print(f"-- worker exited [{info(runs, rid, claude)['state']}]")
                break
        elif not pid_alive(runs, rid):
            print(f"-- worker exited [{info(runs, rid, claude)['state']}]")
            break


def cmd_summary(runs, rid):
    i = info(runs, rid)
    r = i["result"] or {}
    secs = round((r.get("duration_ms") or 0) / 1000)
    print(f"{rid}: {i['state']}  session={i['session'] or '-'}  turns={r.get('num_turns', '-')}  "
          f"tools={i['tools']}  secs={secs}")
    if r.get("result"):
        print(str(r["result"])[:1500])
    print(f"log={os.path.join(runs, rid + '.jsonl')}")


def main():
    ap = argparse.ArgumentParser(prog="ds-status")
    ap.add_argument("--runs", required=True)
    ap.add_argument("--claude", default=os.environ.get("DS_CLAUDE_BIN") or "claude",
                    help="claude CLI used to read background sessions")
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("list")
    p.add_argument("-a", "--all", action="store_true")
    p = sub.add_parser("show")
    p.add_argument("ref")
    p.add_argument("-n", type=int, default=20)
    p.add_argument("-f", "--follow", action="store_true")
    p = sub.add_parser("summary")
    p.add_argument("rid")
    a = ap.parse_args()
    if a.cmd == "list":
        cmd_list(a.runs, a.all, a.claude)
    elif a.cmd == "show":
        cmd_show(a.runs, a.ref, a.n, a.follow, a.claude)
    else:
        cmd_summary(a.runs, a.rid)


if __name__ == "__main__":
    try:
        main()
    except (KeyboardInterrupt, BrokenPipeError):
        pass
