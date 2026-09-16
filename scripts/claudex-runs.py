#!/usr/bin/env python3
"""Shared logic for claudex-status / claudex-cancel. Usage:
   claudex-runs.py status <root>
   claudex-runs.py cancel <root> [--keep-worktrees]
"""
import json, os, sys, time, signal, subprocess

def registry_root(directory):
    directory = os.path.realpath(directory)
    try:
        result = subprocess.run(["git", "-C", directory, "worktree", "list", "--porcelain"], capture_output=True, text=True)
        if result.returncode == 0:
            for line in result.stdout.splitlines():
                if line.startswith("worktree "): return os.path.realpath(line[9:])
    except OSError: pass
    return directory

def load(root):
    p = os.path.join(root, ".claude", "claudex-logs", "runs.jsonl")
    runs = {}
    if os.path.exists(p):
        for line in open(p, encoding="utf-8", errors="replace"):
            line = line.strip()
            if not line: continue
            try: r = json.loads(line)
            except json.JSONDecodeError: continue
            if not isinstance(r, dict) or not isinstance(r.get("id"), str): continue
            cur = runs.setdefault(r["id"], {})
            if cur.get("status") in ("done", "failed", "timeout") and r.get("status") in ("cancelled", "stale"):
                continue  # a completed run cannot be cancelled retroactively (cancel/done race)
            cur.update(r)
    for r in runs.values():
        for key in ("mode", "effort", "title", "status", "dir"):
            if not isinstance(r.get(key), str): r[key] = "?"
        for key in ("duration", "tokens", "ts"):
            if type(r.get(key)) is not int: r[key] = 0
        try: time.localtime(r["ts"])
        except (OverflowError, OSError, ValueError): r["ts"] = 0
    return p, runs

def alive(pid):
    if type(pid) is not int or pid <= 0: return False
    # Git Bash records MSYS PIDs. Native Windows os.kill(pid, 0) is not a probe.
    if os.name == "nt":
        try:
            return subprocess.run(["bash", "-c", 'kill -0 "$1"', "claudex", str(pid)], capture_output=True).returncode == 0
        except OSError: return False
    try: os.kill(pid, 0); return True
    except ProcessLookupError: return False
    except PermissionError: return True
    except Exception: return False

def send_signal(pid, sig):
    if os.name == "nt":
        subprocess.run(["bash", "-c", 'kill "-$1" "$2"', "claudex", str(int(sig)), str(pid)], capture_output=True, check=True)
    else: os.kill(pid, sig)

def ps_field(pid, field):
    try:
        result = subprocess.run(["ps", "-o", field + "=", "-p", str(pid)], capture_output=True, text=True)
        if result.returncode == 0: return result.stdout.strip()
    except OSError: pass
    return None

def matches_process(pid, command, pstart=None):
    if not alive(pid): return False
    actual = ps_field(pid, "command")
    if actual is not None and command not in actual: return False
    if pstart:
        actual = ps_field(pid, "lstart")
        # identity was recorded at start; if we cannot verify it now, do not signal
        if actual is None or actual != pstart: return False
    return True

def append_event(path, event):
    with open(path, "a", encoding="utf-8") as f:
        f.write(json.dumps(event, separators=(",", ":")) + "\n")

def mark_stale(root, record):
    path, latest = load(root)
    record["status"] = latest.get(record["id"], {}).get("status")
    if record["status"] in ("running", "cancelled"):
        append_event(path, {"id": record["id"], "status": "stale"})
        record["status"] = "stale"

def fmt_dur(s):
    s = int(s); return f"{s//60}m{s%60:02d}s" if s >= 60 else f"{s}s"

def worktrees(root):
    try:
        out = subprocess.run(["git", "-C", root, "worktree", "list", "--porcelain"], capture_output=True, text=True).stdout
    except Exception: return []
    wts, cur = [], {}
    for line in out.splitlines():
        if line.startswith("worktree "): cur = {"path": line[9:]}; wts.append(cur)
        elif line.startswith("branch "): cur["branch"] = line[7:].replace("refs/heads/", "")
    main = os.path.realpath(root)
    parent = os.path.join(main, ".claudex-wt")
    managed = []
    for w in wts:
        path = os.path.realpath(w["path"])
        try: inside = os.path.commonpath([parent, path]) == parent and path != parent
        except ValueError: inside = False
        if inside and path != main and w.get("branch", "").startswith("claudex/"): managed.append(w)
    return managed

def status(root):
    p, runs = load(root)
    now = time.time()
    for r in runs.values():
        if r.get("status") == "running" and now - r["ts"] > 24 * 60 * 60 and not alive(r.get("pid")):
            mark_stale(root, r)
    running = [r for r in runs.values() if r.get("status") == "running" and alive(r.get("pid"))]
    stale   = [r for r in runs.values() if r.get("status") == "running" and not alive(r.get("pid"))]
    done    = sorted([r for r in runs.values() if r.get("status") not in ("running",)], key=lambda r: r["ts"], reverse=True)[:10]
    print(f"CLAUDEX status for {root}")
    print(f"\nRunning ({len(running)}):")
    for r in running:
        rel = os.path.relpath(r["dir"], root) if r["dir"].startswith(root) else r["dir"]
        print(f"  {r['mode']:<6} {r['effort']:<7} {fmt_dur(now - r['ts']):>7}  {rel:<24} {r.get('title','')[:60]}")
    if not running: print("  none")
    if stale:
        print(f"\nStale (recorded running, process gone): {len(stale)} — a killed session; run /claudex-cancel to clean up")
    print(f"\nRecent ({len(done)}):")
    for r in done:
        tok = r.get("tokens", 0); tok = min(int(tok), 10**12) if isinstance(tok, int) else 0
        tok = f"{tok/1000:.1f}k" if tok else "-"
        when = time.strftime("%m-%d %H:%M", time.localtime(r["ts"]))
        print(f"  {when} {r['status']:<9} {r['mode']:<6} {r['effort']:<7} {fmt_dur(r.get('duration',0)):>7} {tok:>7}  {r.get('title','')[:50]}")
    if not done: print("  none")
    wts = worktrees(root)
    print(f"\nBuild worktrees ({len(wts)}):")
    for w in wts: print(f"  {w['path']}  [{w.get('branch','?')}]")
    if not wts: print("  none")

def cancel(root, keep):
    p, runs = load(root)
    killed = 0
    signalled = []
    for r in runs.values():
        if r.get("status") != "running": continue
        # each target is verified on its own: a dead wrapper must not stop us from cancelling
        # a live codex child (which would otherwise keep working in a deleted worktree)
        targets = [(r.get("pid"), "codex", r.get("pstart")), (r.get("wpid"), "claudex", r.get("wstart"))]
        live = [t for t in targets if t[0] and alive(t[0])]
        verified = [t for t in live if matches_process(*t)]
        if not live or not verified:
            mark_stale(root, r); continue
        for pid, command, pstart in verified:
            if not matches_process(pid, command, pstart): continue   # recheck right before signalling
            try: send_signal(pid, signal.SIGTERM); killed += 1
            except Exception: pass
        codex_verified = any(t[0] == r.get("pid") for t in verified)
        if not codex_verified:
            mark_stale(root, r); continue   # wrapper signalled, but the worker could not be confirmed
        signalled.append(r)
        _, latest = load(root)
        if latest.get(r["id"], {}).get("status") == "running":
            append_event(p, {"id": r["id"], "ts": int(time.time()), "status": "cancelled",
                             "duration": int(time.time() - r["ts"])})
    time.sleep(1)
    for r in signalled:
        _, latest = load(root)
        if latest.get(r["id"], {}).get("status") not in ("running", "cancelled"): continue  # finished meanwhile
        if alive(r.get("pid")) and matches_process(r["pid"], "codex", r.get("pstart")):
            try: send_signal(r["pid"], getattr(signal, "SIGKILL", 9))
            except Exception: pass
    print(f"cancelled {killed} process(es)")
    wts = worktrees(root)
    if keep:
        print(f"kept {len(wts)} build worktree(s)")
        return
    for w in wts:
        subprocess.run(["git", "-C", root, "worktree", "remove", "--force", w["path"]], capture_output=True)
        if w.get("branch"):
            subprocess.run(["git", "-C", root, "branch", "-D", w["branch"]], capture_output=True)
        print(f"removed worktree {w['path']} and branch {w.get('branch','')}")
    subprocess.run(["git", "-C", root, "worktree", "prune"], capture_output=True)
    wtdir = os.path.join(root, ".claudex-wt")
    if os.path.isdir(wtdir) and not os.listdir(wtdir): os.rmdir(wtdir)

if __name__ == "__main__":
    cmd, root = sys.argv[1], registry_root(sys.argv[2])
    if cmd == "status": status(root)
    elif cmd == "cancel": cancel(root, "--keep-worktrees" in sys.argv[3:])
    else: sys.exit("unknown command")
