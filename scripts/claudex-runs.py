#!/usr/bin/env python3
"""Shared registry, budget and review-reminder logic. Usage:
   claudex-runs.py status <root>
   claudex-runs.py cancel <root> [--keep-worktrees]
   claudex-runs.py merge <root>
   claudex-runs.py count-running <root> <mode>
   claudex-runs.py budget <root> [--warn-only]
   claudex-runs.py fingerprint <dir>
   claudex-runs.py ack <root>
"""
import hashlib, json, math, os, re, sys, time, signal, stat, subprocess

def registry_root(directory, deadline=None):
    directory = os.path.realpath(directory)
    try:
        result = subprocess.run(["git", "-C", directory, "worktree", "list", "--porcelain"], capture_output=True, text=True,
                                timeout=remaining(deadline))
        if result.returncode == 0:
            for line in result.stdout.splitlines():
                if line.startswith("worktree "): return os.path.realpath(line[9:])
    except OSError: pass
    return directory

def remaining(deadline):
    return max(0.001, deadline - time.monotonic()) if deadline is not None else None

def project_path(directory, deadline=None):
    # Hook JSON bypasses Git Bash's automatic argv path conversion.
    if os.name == "nt" and directory.startswith("/"):
        directory = subprocess.run(["cygpath", "-m", directory], capture_output=True,
                                   text=True, check=True, timeout=remaining(deadline)).stdout.strip()
    return os.path.realpath(directory)

def limits(root):
    values = {"max_builders": 4, "budget_minutes": 60}
    try:
        with open(os.path.join(root, ".claude", "claudex.conf"), encoding="utf-8") as f:
            for line in f:
                key, sep, value = line.strip().partition("=")
                if sep and key in values and value.isascii() and value.isdigit():
                    values[key] = int(value)
    except OSError: pass
    return values

def count_running(root, mode):
    return sum(r["status"] == "running" and r["mode"] == mode
               and matches_process(r.get("pid"), r.get("command", "codex"), r.get("pstart"))
               for r in load(root)[1].values())

def budget(root, warn_only=False):
    now = time.time()
    seconds = sum(max(0, r["duration"]) for r in load(root)[1].values()
                  if r["status"] in ("done", "failed", "timeout", "cancelled")
                  and now - 86400 <= r["ts"] <= now)
    limit = limits(root)["budget_minutes"]
    used = format(seconds / 60, ".2f").rstrip("0").rstrip(".")
    if not warn_only:
        print(f"claudex: budget — {used} min used in last 24h (budget {limit})")
    if seconds > limit * 60:
        print(f"claudex: budget warning — {used} min used in last 24h (budget {limit})", file=sys.stderr)

# Shared by ack and the Stop hook. NUL-delimited paths handle spaces/newlines and
# --no-optional-locks prevents read-only hook commands from refreshing the index.
CHANGE_PATHS = (".", ":(exclude).claude", ":(exclude).claudex-wt")

def git_bytes(root, *args, deadline=None):
    return subprocess.run(["git", "--no-optional-locks", "-C", root, *args],
                          capture_output=True, check=True, timeout=remaining(deadline)).stdout

def changes(root, deadline=None):
    diff = git_bytes(root, "diff", "--relative", "--no-ext-diff", "--no-textconv", "HEAD", "--", *CHANGE_PATHS, deadline=deadline)
    untracked = git_bytes(root, "ls-files", "--others", "--exclude-standard", "-z", "--", *CHANGE_PATHS, deadline=deadline)
    return diff, sorted(path for path in untracked.split(b"\0") if path)

def normalize_text(data):
    if b"\0" not in data:
        try: data.decode("utf-8")
        except UnicodeDecodeError: pass
        else: return data.replace(b"\r\n", b"\n")
    return data

def fingerprint(root, deadline=None, snapshot=None):
    """Deterministic content fingerprint of the working tree's in-scope changes.

    Policy (fixed, independent of timing): tracked diff + every untracked in-scope file.
    The first 300 untracked files (sorted) contribute a content hash when they are regular
    files or symlinks of at most 1 MiB; anything else contributes path+size only. If the
    hard deadline is hit the result is marked incomplete so it can never match a stored
    review/ack fingerprint (the hook then stays conservative; `claudex ack` still works).
    """
    diff, untracked = changes(root, deadline) if snapshot is None else snapshot
    digest = hashlib.sha256(normalize_text(diff) + b"\0")
    incomplete = False
    for index, path in enumerate(sorted(untracked)):
        if deadline is not None and time.monotonic() >= deadline:
            incomplete = True; break
        filename = os.path.join(root, os.fsdecode(path))
        try: info = os.lstat(filename)
        except OSError: digest.update(path + b"\0missing\0"); continue
        digest.update(path + b"\0")
        hashable = index < 300 and info.st_size <= 1024 * 1024 and (stat.S_ISREG(info.st_mode) or stat.S_ISLNK(info.st_mode))
        if not hashable:  # too large / special: size + mtime (deterministic for an unchanged tree)
            digest.update(b"stat:" + str(info.st_size).encode("ascii") + b":" + str(info.st_mtime_ns).encode("ascii") + b"\0"); continue
        try:
            if stat.S_ISLNK(info.st_mode): data = os.fsencode(os.readlink(filename))
            else:
                with open(filename, "rb") as f: data = f.read(1024 * 1024 + 1)
        except OSError: digest.update(b"unreadable\0"); continue
        if len(data) > 1024 * 1024: digest.update(b"stat:" + str(info.st_size).encode("ascii") + b":" + str(info.st_mtime_ns).encode("ascii") + b"\0")
        else: digest.update(b"sha256:" + hashlib.sha256(normalize_text(data)).hexdigest().encode("ascii") + b"\0")
    value = digest.hexdigest()
    return ("incomplete:" + value) if incomplete else value

def acknowledge(root, value=None):
    value = fingerprint(root) if value is None else value
    path = os.path.join(root, ".claude", "claudex-logs", ".reviewed")
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as f: f.write(value + "\n")

def stop_hook(launcher):
    deadline = time.monotonic() + 5
    try:
        payload = json.load(sys.stdin)
        if payload.get("stop_hook_active") is True: return
        root = project_path(payload["cwd"], deadline)
        with open(os.path.join(root, "CLAUDE.md"), encoding="utf-8") as f:
            if "claudex-auto:start" not in f.read(): return
        snapshot = changes(root, deadline)
        if not snapshot[0] and not snapshot[1]: return
        value = fingerprint(root, deadline, snapshot)
        try:
            with open(os.path.join(root, ".claude", "claudex-logs", ".reviewed"), encoding="utf-8") as f:
                if value in f.read().splitlines(): return
        except FileNotFoundError: pass
        shared_root = registry_root(root, deadline)
        runs = load(shared_root)[1]
        if any(r["status"] == "done" and r["mode"] == "review"
               and r.get("scope") == "uncommitted" and r["dir"] == root
               and r.get("fingerprint") == value for r in runs.values()):
            acknowledge(root, value)
            return
        # Quote for Bash, including spaces and shell metacharacters in project paths.
        def quote(path):
            if os.name == "nt": path = path.replace("\\", "/")
            return '"' + path.replace("\\", "\\\\").replace('"', '\\"').replace("$", "\\$").replace("`", "\\`") + '"'
        edits = direct_edits(shared_root, runs)
        suffix = f": Claude edited {edits} file(s) directly this change set" if edits else ""
        if time.monotonic() >= deadline: return
        print(json.dumps({"decision": "block", "reason":
            "CLAUDEX: there are uncommitted changes that have not been reviewed. "
            "Run a review (claudex agent 'review: <dir>') and verify its findings, or, "
            "if the user explicitly wants to skip, run: " + quote(launcher) + " ack -C " + quote(root) + suffix}))
    except Exception:
        return  # hooks must be silent and must not obstruct stopping on errors

def guarded_hook(command, launcher):
    # Buffer all output in a supervisor. This also bounds blocked stdin, filesystem
    # reads and registry parsing on Windows, where SIGALRM is unavailable.
    started = time.monotonic()
    try:
        result = subprocess.run([sys.executable, os.path.abspath(__file__), command, launcher],
                                stdin=sys.stdin, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                                timeout=4.5)
        if result.returncode == 0 and time.monotonic() - started < 5:
            sys.stdout.buffer.write(result.stdout)
    except Exception: pass

def edit_hook():
    try:
        deadline = time.monotonic() + 5
        payload = json.load(sys.stdin)
        if payload.get("tool_name") not in ("Edit", "Write", "MultiEdit"): return
        directory = project_path(payload["cwd"], deadline)
        with open(os.path.join(directory, "CLAUDE.md"), encoding="utf-8") as f:
            if "claudex-auto:start" not in f.read(): return
        path = payload["tool_input"]["file_path"]
        if not isinstance(path, str) or not path: return
        path = project_path(os.path.join(directory, path), deadline)
        root = registry_root(directory, deadline)
        log = os.path.join(root, ".claude", "claudex-logs", "edits.jsonl")
        if time.monotonic() >= deadline: return
        os.makedirs(os.path.dirname(log), exist_ok=True)
        append_event(log, dict(ts=time.time(), path=path))
    except Exception: pass

def direct_edits(root, runs=None):
    if runs is None: runs = load(root)[1]
    since = max((r["ts"] for r in runs.values()
                 if r["status"] == "done" and r["mode"] in ("build", "review")), default=0)
    paths = set()
    try:
        with open(os.path.join(root, ".claude", "claudex-logs", "edits.jsonl"), encoding="utf-8") as f:
            for line in f:
                try:
                    event = json.loads(line)
                    if (isinstance(event, dict) and type(event.get("ts")) in (int, float)
                            and event["ts"] > since and isinstance(event.get("path"), str)):
                        paths.add(event["path"])
                except ValueError: pass
    except OSError: pass
    return len(paths)

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
        for key in ("duration", "tokens"):
            if type(r.get(key)) is not int: r[key] = 0
        if type(r.get("ts")) not in (int, float) or (type(r["ts"]) is float and not math.isfinite(r["ts"])): r["ts"] = 0
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

def merge(root):
    def git(directory, *args, check=True):
        return subprocess.run(["git", "-C", directory, *args], capture_output=True,
                              check=check)
    def paths(output):
        return {os.fsdecode(path) for path in output.split(b"\0") if path}
    def display(files):
        return ", ".join(json.dumps(path, ensure_ascii=False) for path in sorted(files)) or "none"
    try:
        # the tool's own folders never count as dirt
        if git(root, "status", "--porcelain", "--untracked-files=all", "--", ".", ":(exclude).claudex-wt", ":(exclude).claude/claudex-logs").stdout:
            print("claudex: merge refused: current tree is dirty", file=sys.stderr)
            return 2
        managed = sorted(worktrees(root), key=lambda w: w["branch"])
        # Finish all builder commits before comparing or merging any branches.
        for worktree in managed:
            added = git(worktree["path"], "add", "-A", "--", ".", ":!.claude/claudex-logs", check=False)
            if added.returncode:
                # Some Git versions complain about an ignored .claude parent in
                # the exclusion even after staging all intended changes. Accept
                # that only when no eligible unstaged/untracked files remain.
                pending = git(worktree["path"], "diff", "--quiet", "--", ".", ":!.claude/claudex-logs", check=False)
                untracked = git(worktree["path"], "ls-files", "--others", "--exclude-standard", "-z",
                                "--", ".", ":!.claude/claudex-logs").stdout
                if pending.returncode or untracked:
                    raise subprocess.CalledProcessError(added.returncode, added.args, stderr=added.stderr)
            staged = git(worktree["path"], "diff", "--cached", "--quiet", check=False)
            if staged.returncode == 1:
                git(worktree["path"], "commit", "-m", "claudex: " + worktree["branch"])
            elif staged.returncode:
                raise subprocess.CalledProcessError(staged.returncode, staged.args, stderr=staged.stderr)
        overlaps = []
        for index, left in enumerate(managed):
            for right in managed[index + 1:]:
                base = git(root, "merge-base", left["branch"], right["branch"]).stdout.decode().strip()
                changed = [paths(git(root, "diff", "--name-only", "--no-renames", "-z", base, w["branch"], "--").stdout)
                           for w in (left, right)]
                overlaps.append((left["branch"], right["branch"], changed[0] & changed[1]))
        merged, conflicts = [], []
        for worktree in managed:
            branch = worktree["branch"]
            tip = git(root, "rev-parse", branch).stdout.decode().strip()
            result = git(root, "merge", "--no-ff", "--commit", "--no-edit", branch, check=False)
            if result.returncode:
                files = paths(git(root, "diff", "--name-only", "--diff-filter=U", "-z").stdout)
                # A non-conflict Git error must not be reported as a successful merge.
                abort = git(root, "merge", "--abort", check=False)
                if not files or abort.returncode:
                    raise subprocess.CalledProcessError(result.returncode, result.args, stderr=result.stderr)
                conflicts.append((branch, files))
                continue
            # Only clean up once the builder's tip is really in HEAD and no merge is pending
            # (a merge.mergeOptions/--no-commit config can return 0 without committing).
            pending = os.path.exists(os.path.join(git(root, "rev-parse", "--git-dir").stdout.decode().strip(), "MERGE_HEAD"))
            contained = git(root, "merge-base", "--is-ancestor", tip, "HEAD", check=False).returncode == 0
            if pending or not contained:
                conflicts.append((branch, {"(merge did not commit: tip %s not in HEAD)" % tip[:10]}))
                if pending: git(root, "merge", "--abort", check=False)
                continue
            merged.append(branch)
            git(root, "worktree", "remove", worktree["path"])
            git(root, "branch", "-d", branch)
        print("Merged branches:")
        for branch in merged: print("  MERGED " + branch)
        if not merged: print("  none")
        print("Conflicting branches:")
        for branch, files in conflicts: print("  CONFLICT " + branch + ": " + display(files))
        if not conflicts: print("  none")
        print("Overlap table:")
        print("  Branch A | Branch B | Files")
        for left, right, files in overlaps: print(f"  {left} | {right} | {display(files)}")
        if not overlaps: print("  none")
        return 4 if conflicts else 0
    except (OSError, subprocess.SubprocessError) as error:
        detail = getattr(error, "stderr", None)
        print("claudex: merge failed: " + (os.fsdecode(detail).strip() if detail else str(error)), file=sys.stderr)
        return 2

def status(root):
    budget(root, warn_only=True)
    p, runs = load(root)
    now = time.time()
    for r in runs.values():
        if r.get("status") == "running" and now - r["ts"] > 24 * 60 * 60 and not alive(r.get("pid")):
            mark_stale(root, r)
    running = [r for r in runs.values() if r.get("status") == "running" and alive(r.get("pid"))]
    stale   = [r for r in runs.values() if r.get("status") == "running" and not alive(r.get("pid"))]
    done    = sorted([r for r in runs.values() if r.get("status") not in ("running",)], key=lambda r: r["ts"], reverse=True)[:10]
    print(f"CLAUDEX status for {root}")
    print(f"Direct edits by Claude since last build/review: {direct_edits(root, runs)} files")
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
        targets = [(r.get("pid"), r.get("command", "codex"), r.get("pstart")), (r.get("wpid"), "claudex", r.get("wstart"))]
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
        if matches_process(r.get("pid"), r.get("command", "codex"), r.get("pstart")):
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

# ---------------------------------------------------------------------------
# Context packets: everything a review needs, assembled by git, so Codex does not
# spend its first N tool calls rediscovering the repo on every run.
PACKET_FILE_LIMIT = 48 * 1024      # per file; larger files get head+tail
PACKET_TOTAL_LIMIT = 220 * 1024    # all file bodies together
CONVENTION_FILES = ("AGENTS.md", "CLAUDE.md", ".codex/AGENTS.md")
# review scope excludes only generated dirs (NOT all of .claude — hooks/settings changes are real changes)
PACKET_PATHS = (".", ":(exclude).claude/claudex-logs", ":(exclude).claudex-wt")

class PacketError(Exception): pass

def _git_out(root, *args):
    """git stdout as bytes; raises PacketError with git's message on failure."""
    r = subprocess.run(["git", "--no-optional-locks", "-C", root, *args], capture_output=True)
    if r.returncode: raise PacketError((r.stderr or b"git failed").decode("utf-8", "replace").strip())
    return r.stdout

def _limit_body(data, total, limit=PACKET_FILE_LIMIT):
    """head+tail of `data` (already the full content or a real tail-inclusive read)."""
    if b"\0" in data[:8192]: return b"<binary file omitted>"
    data = normalize_text(data)
    if total <= limit and len(data) <= limit: return data
    head, tail = data[: limit * 2 // 3], data[-(limit // 3):]
    return head + b"\n\n[... %d bytes omitted ...]\n\n" % (max(total, len(data)) - len(head) - len(tail)) + tail

def _read_limited(path, limit=PACKET_FILE_LIMIT):
    try:
        size = os.path.getsize(path)
        with open(path, "rb") as f:
            if size <= limit * 4: return _limit_body(f.read(), size, limit)
            head = f.read(limit)                  # real head and real tail of a large file
            f.seek(-limit, os.SEEK_END); tail = f.read(limit)
        return _limit_body(head + b"\n" + tail, size, limit)
    except OSError: return None

def _conventions(root):
    parts = []
    for name in CONVENTION_FILES:
        path = os.path.join(root, name)
        if not os.path.isfile(path): continue
        text = _read_limited(path, 12 * 1024) or b""
        text = re.sub(rb"<!-- claudex-auto:start -->.*?<!-- claudex-auto:end -->\n?", b"", text, flags=re.S)
        if text.strip(): parts.append(b"### " + name.encode() + b"\n" + text.strip() + b"\n")
    return b"\n".join(parts) if parts else b"(no AGENTS.md / CLAUDE.md in this project)\n"

def _test_command(root):
    pkg = os.path.join(root, "package.json")
    if os.path.isfile(pkg):
        try:
            data = json.load(open(pkg, encoding="utf-8"))
            scripts = data.get("scripts") if isinstance(data, dict) else None
            if isinstance(scripts, dict):
                runner = "bun" if any(os.path.isfile(os.path.join(root, f)) for f in ("bun.lock", "bun.lockb")) else \
                         "pnpm" if os.path.isfile(os.path.join(root, "pnpm-lock.yaml")) else \
                         "yarn" if os.path.isfile(os.path.join(root, "yarn.lock")) else "npm"
                names = [n for n in scripts if isinstance(n, str) and (n == "test" or n.startswith("test:"))]
                if names: return "; ".join(f"{runner} run {n}" for n in names[:4])
        except (ValueError, OSError, AttributeError, TypeError): pass
    for probe, cmd in (("pytest.ini", "pytest"), ("pyproject.toml", "pytest"), ("setup.cfg", "pytest"),
                       ("Cargo.toml", "cargo test"), ("go.mod", "go test ./..."), ("Makefile", "make test")):
        if os.path.isfile(os.path.join(root, probe)): return cmd
    return "(no test command detected)"

def _name_status_z(raw):
    """Parse `--name-status -z` output into [(status_letter, path_bytes)], handling renames/copies."""
    fields = [f for f in raw.split(b"\0")]
    out, i = [], 0
    while i < len(fields):
        st = fields[i]
        if not st: i += 1; continue
        if st[:1] in (b"R", b"C") and i + 2 < len(fields): out.append((st[:1].decode(), fields[i + 2])); i += 3
        elif i + 1 < len(fields): out.append((st[:1].decode(), fields[i + 1])); i += 2
        else: break
    return out

def scope_diff(root, scope):
    """(diff_bytes, [(status, path_bytes)]) for the scope; paths are relative to `root` (a subdir works)."""
    kind = scope[0]
    if kind == "uncommitted":
        diff = _git_out(root, "diff", "HEAD", "--relative", "--no-ext-diff", "--", *PACKET_PATHS)
        files = _name_status_z(_git_out(root, "diff", "HEAD", "--relative", "--name-status", "-z", "--", *PACKET_PATHS))
        untracked = [p for p in _git_out(root, "ls-files", "--others", "--exclude-standard", "-z", "--", *PACKET_PATHS).split(b"\0") if p]
        for p in untracked:
            files.append(("A", p))
            body = _read_limited(os.path.join(root, os.fsdecode(p)))
            if body is not None and body != b"<binary file omitted>":
                diff += b"\n--- /dev/null\n+++ b/" + p + b"\n" + b"".join(b"+" + line + b"\n" for line in body.split(b"\n"))
        return diff, files
    if kind == "base":
        rng = f"{scope[1]}...HEAD"
        return (_git_out(root, "diff", rng, "--relative", "--no-ext-diff", "--", *PACKET_PATHS),
                _name_status_z(_git_out(root, "diff", rng, "--relative", "--name-status", "-z", "--", *PACKET_PATHS)))
    if kind == "commit":
        return (_git_out(root, "show", scope[1], "--format=%H %s%n%b", "--relative", "--no-ext-diff", "--", *PACKET_PATHS),
                _name_status_z(_git_out(root, "show", scope[1], "--format=", "--relative", "--name-status", "-z", "--", *PACKET_PATHS)))
    raise PacketError("unknown scope")

def _fence(body):
    longest = max((len(m) for m in re.findall(rb"`{3,}", body)), default=0)
    return b"`" * max(3, longest + 1)

def _body_at(root, scope, path):
    """Post-change contents: working tree for uncommitted, HEAD for --base, the commit for --commit."""
    if scope[0] == "uncommitted": return _read_limited(os.path.join(root, os.fsdecode(path)))
    rev = "HEAD" if scope[0] == "base" else scope[1]
    prefix = _git_out(root, "rev-parse", "--show-prefix").decode().strip()
    try: data = _git_out(root, "show", f"{rev}:{prefix}{os.fsdecode(path)}")
    except PacketError: return None
    return _limit_body(data, len(data))

def packet(root, scope):
    diff, files = scope_diff(root, scope)
    out = [b"## Project conventions (already loaded; do not search for AGENTS.md)\n", _conventions(root),
           b"\n## Test command\n", _test_command(root).encode() + b"\n",
           b"\n## Changed files (%d)\n" % len(files)]
    out += [b"- " + st.encode() + b" " + path + b"\n" for st, path in files]
    f = _fence(diff)
    out += [b"\n## Diff\n", f + b"diff\n", diff.rstrip(b"\n"), b"\n" + f + b"\n"]
    budget = PACKET_TOTAL_LIMIT
    out.append(b"\n## Full contents of changed files (post-change)\n")
    for st, path in files:
        if st == "D": continue
        body = _body_at(root, scope, path)
        if body is None: continue
        if budget - len(body) < 0:
            out.append(b"\n### " + path + b"\n(omitted: packet size limit reached; read it yourself if needed)\n"); continue
        budget -= len(body)
        f = _fence(body)
        out += [b"\n### " + path + b"\n", f + b"\n", body.rstrip(b"\n"), b"\n" + f + b"\n"]
    return b"".join(out)

def last_session(root, directory, mode):
    """Newest done record of `mode` for this directory that has a codex session id."""
    _, runs = load(root)
    best = None
    for r in runs.values():
        if r.get("status") != "done" or r.get("mode") != mode or not r.get("session"): continue
        if os.path.realpath(r.get("dir", "")) != os.path.realpath(directory): continue
        if best is None or r["ts"] > best["ts"]: best = r
    return best


if __name__ == "__main__":
    cmd, directory = sys.argv[1:3]
    if cmd == "guard-stop-hook": guarded_hook("stop-hook", directory)
    elif cmd == "guard-edit-hook": guarded_hook("edit-hook", directory)
    elif cmd == "edit-hook": edit_hook()
    elif cmd == "stop-hook": stop_hook(directory)
    elif cmd == "fingerprint": print(fingerprint(os.path.realpath(directory)))
    elif cmd == "ack": acknowledge(os.path.realpath(directory))
    elif cmd in ("packet", "scope-diff"):
        args = sys.argv[3:]
        scope = ("uncommitted",)
        if args and args[0] == "--base": scope = ("base", args[1])
        elif args and args[0] == "--commit": scope = ("commit", args[1])
        try:
            if cmd == "packet": sys.stdout.buffer.write(packet(os.path.realpath(directory), scope))
            else:
                diff, files = scope_diff(os.path.realpath(directory), scope)
                sys.stdout.buffer.write(diff)
        except PacketError as e:
            sys.stderr.write("claudex: cannot build context for scope %s: %s\n" % (" ".join(scope), e)); sys.exit(2)
    elif cmd == "last-session":
        r = last_session(registry_root(directory), directory, sys.argv[3])
        print(json.dumps({k: r.get(k) for k in ("id", "session", "log", "ts", "fingerprint")}) if r else "")
    else:
        root = registry_root(directory)
        if cmd == "merge": sys.exit(merge(root))
        elif cmd == "status": status(root)
        elif cmd == "cancel": cancel(root, "--keep-worktrees" in sys.argv[3:])
        elif cmd == "count-running": print(count_running(root, sys.argv[3]))
        elif cmd == "max-builders": print(limits(root)["max_builders"])
        elif cmd == "budget": budget(root, "--warn-only" in sys.argv[3:])
        else: sys.exit("unknown command")
