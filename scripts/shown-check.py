#!/usr/bin/env python3
"""Did the agent actually write the progress block into the chat?

Usage: shown-check.py <code>
Prints one word: text, toolonly, or unknown.

Claude Code keeps a transcript of the session on disk. The block carries a short
code, so the transcript shows whether that code appeared in the agent's own
message text or only inside a tool result. Other runtimes keep no transcript
this script knows of, and get "unknown".
"""
import glob, json, os, sys, time

code = sys.argv[1]
needle = "· " + code
roots = [os.environ.get("CLAUDE_CONFIG_DIR", ""), os.path.expanduser("~/.claude")]
files = []
for r in roots:
    if r:
        files += glob.glob(os.path.join(r, "projects", "**", "*.jsonl"), recursive=True)
recent = [f for f in set(files) if time.time() - os.path.getmtime(f) < 900]

def scan():
    seen_tool = False
    for f in recent:
        try:
            lines = [l for l in open(f, errors="replace") if code in l]
        except OSError:
            continue
        for l in lines:
            try:
                d = json.loads(l)
            except ValueError:
                continue
            content = (d.get("message") or {}).get("content")
            if not isinstance(content, list):
                continue
            for b in content:
                if b.get("type") == "text" and d.get("type") == "assistant" and needle in b.get("text", "") and "| Phase | Detail |" in b.get("text", ""):
                    return "text"
                if b.get("type") == "tool_result" and code in json.dumps(b):
                    seen_tool = True
    return "toolonly" if seen_tool else "unknown"

res = scan()
for _ in range(4):
    if res == "text" or (res == "unknown" and not os.environ.get("CLAUDECODE")):
        break
    time.sleep(1)
    res = scan()
# Inside Claude Code a transcript always exists, so no trace of the code means
# the display and this check were chained into one command.
if res == "unknown" and os.environ.get("CLAUDECODE"):
    res = "toolonly"
print(res)
