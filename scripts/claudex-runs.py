#!/usr/bin/env python3
"""Shared logic for claudex-status / claudex-cancel. Usage:
   claudex-runs.py status <root>
   claudex-runs.py cancel <root> [--keep-worktrees]
"""
import json, os, sys, time, signal, subprocess

def load(root):
    p = os.path.join(root, ".claude", "claudex-logs", "runs.jsonl")
    runs = {}
    if os.path.exists(p):
        for line in open(p, encoding="utf-8", errors="replace"):
            line = line.strip()
            if not line: continue
            try: r = json.loads(line)
            except json.JSONDecodeError: continue
            cur = runs.setdefault(r["id"], {})
            cur.update(r)
    return p, runs

def alive(pid):
    if not pid: return False
    try: os.kill(pid, 0); return True
    except ProcessLookupError: return False
    except PermissionError: return True
    except Exception: return False

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
    return [w for w in wts if "/.claudex-wt/" in w["path"].replace("\\", "/")]

def status(root):
    p, runs = load(root)
    now = time.time()
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
        tok = r.get("tokens", 0); tok = f"{tok/1000:.1f}k" if tok else "-"
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
    for r in runs.values():
        if r.get("status") != "running": continue
        for pid in (r.get("pid"), r.get("wpid")):
            if alive(pid):
                try: os.kill(pid, signal.SIGTERM); killed += 1
                except Exception: pass
        with open(p, "a") as f:
            f.write(json.dumps({"id": r["id"], "ts": int(time.time()), "status": "cancelled",
                                "duration": int(time.time() - r["ts"])}, separators=(",", ":")) + "\n")
    time.sleep(1)
    for r in runs.values():
        if r.get("status") == "running" and alive(r.get("pid")):
            try: os.kill(r["pid"], signal.SIGKILL)
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
    cmd, root = sys.argv[1], os.path.realpath(sys.argv[2])
    if cmd == "status": status(root)
    elif cmd == "cancel": cancel(root, "--keep-worktrees" in sys.argv[3:])
    else: sys.exit("unknown command")
