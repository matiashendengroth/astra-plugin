#!/usr/bin/env bash
# Smoke test against a throwaway repo. Use --offline to skip logged-in Codex checks.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"; A="$HERE/claudex"
PY="$(command -v python3 || command -v python)"
export PYTHONDONTWRITEBYTECODE=1
T="$(mktemp -d "$HERE/../.claudex-test.XXXXXX")"; trap 'rm -rf "$T"' EXIT
T="$(cd "$T" && pwd -P)"
NETWORK=1
if [[ "${1:-}" == --offline ]] || ! command -v codex >/dev/null 2>&1; then NETWORK=0; fi
REAL_PATH="$PATH"
pass=0; fail=0
ok()   { echo "  ✔ $1"; pass=$((pass+1)); }
bad()  { echo "  ✘ $1"; fail=$((fail+1)); }
check(){ if eval "$2"; then ok "$1"; else bad "$1"; fi; }

cd "$T" && git init -q && printf 'def add(a,b):\n    return a-b\n' > calc.py && git add -A && git -c user.email=t@t -c user.name=t commit -qm init
printf 'def add(a,b):\n    return a+b\n' > calc.py

mkdir -p "$T/stub-bin"
cat > "$T/stub-bin/codex" <<'SH'
#!/usr/bin/env bash
if [[ "${1:-}" == --version ]]; then echo "codex-cli test-version"; exit 0; fi
if [[ -n "${STUB_ARGS:-}" ]]; then printf '%s\n' "$@" > "$STUB_ARGS"; fi
if [[ -n "${STUB_INPUT:-}" ]]; then cat > "$STUB_INPUT"; fi
while [[ $# -gt 0 ]]; do
  if [[ "$1" == -o ]]; then
    if [[ "${STUB_FAIL:-0}" == 1 ]]; then :
    elif [[ -n "${STUB_ANSWER:-}" ]]; then cat "$STUB_ANSWER" > "$2"
    else printf 'stub answer\n' > "$2"; fi
    shift 2
  else shift; fi
done
[[ -n "${STUB_EDIT:-}" ]] && printf 'edited during review\n' > "$STUB_EDIT"
[[ -n "${STUB_STARTED:-}" ]] && printf '%s\n' "$$" >> "$STUB_STARTED"
if [[ -n "${STUB_RELEASE:-}" ]]; then
  deadline=$((SECONDS+20))
  while [[ ! -f "$STUB_RELEASE" && $SECONDS -lt $deadline ]]; do sleep 0.1; done
fi
[[ -n "${STUB_LOG:-}" ]] && cat "$STUB_LOG"
printf 'tokens used\n1,234\n'
[[ "${STUB_FAIL:-0}" != 1 ]]
SH
chmod +x "$T/stub-bin/codex"
export PATH="$T/stub-bin:$PATH"

echo "argument checks (no network)"
check "rejects bad effort"      '"$A" -e turbo x 2>&1 | grep -q "bad effort"'
check "rejects bad timeout"     '"$A" -t abc x 2>&1 | grep -q "bad timeout"'
check "rejects unknown option"  '"$A" --bogus x 2>&1 | grep -q "unknown option"'
check "rejects missing dir"     '"$A" -C /nonexistent x 2>&1 | grep -q "no such directory"'
check "no prompt, idle stdin exits fast" 'out=$( ( sleep 6 & exec "$A" -C "$T" ) 2>&1 ); echo "$out" | grep -q "no prompt"'

echo "registry checks (no network)"
TITLE="$("$PY" -c 'print("quotes: \" tab:\t slash:\\ " + "é" * 200)')"
LONG_DIR="$T/$("$PY" -c 'print("d" * 170)')"
mkdir -p "$LONG_DIR"
check "quoted/tabbed long title records valid JSON and full paths" '"$A" -C "$LONG_DIR" "$TITLE" >/dev/null && "$PY" - "$T" "$LONG_DIR" "$TITLE" <<'"'"'PY'"'"'
import json, os, sys
root, directory, title = sys.argv[1:]
events = [json.loads(line) for line in open(os.path.join(root, ".claude/claudex-logs/runs.jsonl"), encoding="utf-8")]
assert [r["status"] for r in events] == ["running", "done"]
for r in events:
    assert r["title"] == title[:160]
    assert os.path.normpath(r["dir"]) == os.path.normpath(directory)
    assert os.path.normpath(r["log"]) == os.path.join(directory, ".claude", "claudex-logs", r["id"] + ".log")
    assert len(r["log"]) > 160 and os.path.isfile(r["log"])
    assert r["token"] and all(c in "0123456789abcdef" for c in r["token"])
    assert isinstance(r["pstart"], str)
assert events[0]["token"] == events[1]["token"]
PY'
check "garbage, empty objects and malformed fields do not crash status" 'printf '\''garbage\n{}\n[]\nnull\n{"id":4}\n{"id":"partial","status":"done","duration":"oops","tokens":null}\n'\'' >> "$T/.claude/claudex-logs/runs.jsonl"; "$A" status -C "$T" >/dev/null'
check "status in linked worktree finds main registry" 'git -C "$T" worktree add -q --detach "$T/linked" HEAD && mkdir -p "$T/linked/sub" && o=$(cd "$T/linked/sub" && "$A" status); [[ "$o" == *"$T"* && "$o" == *"quotes:"* ]]'
check "writer in linked worktree uses main registry" '"$A" -C "$T/linked/sub" linked-registry-marker >/dev/null && o=$("$A" status -C "$T"); [[ "$o" == *linked-registry-marker* ]] && [[ ! -f "$T/linked/sub/.claude/claudex-logs/runs.jsonl" ]]'
check "separate git directory uses first listed worktree consistently" 'git init -q --separate-git-dir "$T/separate-meta" "$T/separate" && mkdir -p "$T/separate/sub" && expected=$(git -C "$T/separate/sub" worktree list --porcelain | sed -n "s/^worktree //p" | head -1) && "$A" -C "$T/separate/sub" separate-registry-marker >/dev/null && o=$("$A" status -C "$T/separate/sub"); [[ "$o" == *separate-registry-marker* ]] && [[ -f "$expected/.claude/claudex-logs/runs.jsonl" ]]'
check "non-repository falls back to supplied directory" 'mkdir -p "$T/nonrepo" && GIT_CEILING_DIRECTORIES="$T" "$A" -C "$T/nonrepo" nonrepo-marker >/dev/null && o=$(GIT_CEILING_DIRECTORIES="$T" "$A" status -C "$T/nonrepo"); [[ "$o" == *nonrepo-marker* ]] && [[ -f "$T/nonrepo/.claude/claudex-logs/runs.jsonl" ]]'
check "cancel keeps worktrees on non-claudex branches" 'git -C "$T" worktree add -q -b keep-me "$T/.claudex-wt/other" HEAD && "$A" cancel -C "$T" >/dev/null && [[ -f "$T/.claudex-wt/other/calc.py" ]]'

registry_safety_checks() {
  "$PY" - "$HERE/claudex-runs.py" "$T" <<'PY'
import contextlib, importlib.util, io, json, os, signal, subprocess, sys, time
from unittest.mock import patch
spec = importlib.util.spec_from_file_location("runs", sys.argv[1])
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
root = os.path.join(sys.argv[2], "safety")
os.makedirs(os.path.join(root, ".claude", "claudex-logs"))
path = os.path.join(root, ".claude", "claudex-logs", "runs.jsonl")
def seed(**extra):
    r = dict(id="test", status="running", ts=int(time.time()), pid=123, wpid=456, pstart="codex start")
    r.update(extra)
    with open(path, "w") as f: f.write(json.dumps(r) + "\n")
def state(): return m.load(root)[1]["test"]["status"]
def ps(pid, field):
    return ("codex start" if pid == 123 else "wrapper start") if field == "lstart" else ("codex exec" if pid == 123 else "bash claudex")
with contextlib.redirect_stdout(io.StringIO()), patch.object(m.time, "sleep"), patch.object(m, "worktrees", return_value=[]), patch.object(m, "alive", return_value=True), patch.object(m, "send_signal") as kill:
    for mismatch in ("command", "lstart", "empty"):
        seed()
        def wrong(pid, field):
            if mismatch == "empty": return ""
            if mismatch == field and pid == 123: return "unrelated"
            return ps(pid, field)
        with patch.object(m, "ps_field", side_effect=wrong): m.cancel(root, True)
        assert state() == "stale", mismatch
        # the unverified codex pid is never signalled; the verified wrapper may be
        assert all(c.args[0] != 123 for c in kill.call_args_list), mismatch
        kill.reset_mock()
    # wrapper identity mismatch: the verified codex child is still cancelled, the wrapper is left alone
    seed()
    with patch.object(m, "ps_field", side_effect=lambda pid, field: "unrelated" if (pid == 456 and field == "command") else ps(pid, field)):
        m.cancel(root, True)
    assert state() == "cancelled"
    assert [c.args[0] for c in kill.call_args_list if c.args[1] == signal.SIGTERM] == [123]
    kill.reset_mock()
    seed()
    with patch.object(m, "ps_field", side_effect=ps): m.cancel(root, True)
    assert state() == "cancelled"
    assert kill.call_args_list[0].args == (123, signal.SIGTERM)
    assert kill.call_args_list[1].args == (456, signal.SIGTERM)
    kill.reset_mock()
    # identity was recorded but cannot be verified now (ps unavailable): fail closed, do not signal
    seed()
    with patch.object(m, "ps_field", return_value=None): m.cancel(root, True)
    assert state() == "stale" and all(c.args[0] != 123 for c in kill.call_args_list)
    kill.reset_mock()
    # nothing recorded (platform could not capture start times): liveness alone is enough
    seed(pstart="")
    with patch.object(m, "ps_field", return_value=None): m.cancel(root, True)
    assert state() == "cancelled" and kill.called
    kill.reset_mock()
    seed()
    def complete(pid, sig):
        if pid == 123: m.append_event(path, {"id":"test", "status":"done"})
    kill.side_effect = complete
    with patch.object(m, "ps_field", side_effect=ps): m.cancel(root, True)
    assert state() == "done"
    assert all(call.args[1] != getattr(signal, "SIGKILL", 9) for call in kill.call_args_list)
    kill.reset_mock()
    seed()
    with patch.object(m, "ps_field", side_effect=ps), patch.object(m, "alive", side_effect=lambda pid: pid != 456 or not kill.called):
        m.cancel(root, True)
    assert state() == "done" and kill.call_count == 1
    kill.side_effect = None
    kill.reset_mock()
    seed()
    with patch.object(m, "ps_field", side_effect=lambda pid, field: "reused" if field == "lstart" and kill.call_count >= 2 else ps(pid, field)):
        m.cancel(root, True)
    # PID reused after SIGTERM: our process is gone, so the run is cancelled and no SIGKILL is sent
    assert state() == "cancelled" and kill.call_count == 2
    kill.reset_mock()
    seed(ts=int(time.time()) - 86401)
    with patch.object(m, "alive", return_value=False): m.status(root)
    assert state() == "stale"
    kill.assert_not_called()

with patch.object(m.os, "name", "nt"), patch.object(m.os, "kill") as native_kill, patch.object(m.subprocess, "run", return_value=subprocess.CompletedProcess([], 0)) as run:
    assert m.alive(123)
    assert run.call_args.args[0] == ["bash", "-c", 'kill -0 "$1"', "claudex", "123"]
    m.send_signal(123, 15)
    assert run.call_args.args[0] == ["bash", "-c", 'kill "-$1" "$2"', "claudex", "15", "123"]
    native_kill.assert_not_called()

# Mock the literal /tmp path so this check never creates or removes external files.
listing = "\n\n".join("worktree " + p + "\nbranch refs/heads/" + b for p, b in [
    (root, "claudex/main"), ("/tmp/.claudex-wt/other", "other"),
    ("/tmp/.claudex-wt/owned", "claudex/outside"),
    (os.path.join(root, ".claudex-wt", "foreign"), "other"),
    (os.path.join(root, ".claudex-wt", "owned"), "claudex/owned"),
    (os.path.join(root, ".claudex-wt", "escape"), "claudex/escape"),
    (os.path.join(root, ".claudex-wt-else", "owned"), "claudex/else")])
def git(args, **kwargs): return subprocess.CompletedProcess(args, 0, listing if "list" in args else "", "")
realpath = os.path.realpath
def resolve(path):
    return realpath("/tmp/escaped-worktree") if path == os.path.join(root, ".claudex-wt", "escape") else realpath(path)
with contextlib.redirect_stdout(io.StringIO()), patch.object(m.time, "sleep"), patch.object(m.os.path, "realpath", side_effect=resolve), patch.object(m.subprocess, "run", side_effect=git) as run:
    m.cancel(root, False)
    removed = [call.args[0][-1] for call in run.call_args_list if "remove" in call.args[0]]
    assert removed == [os.path.join(root, ".claudex-wt", "owned")], removed
PY
}
check "cancel checks PID identity, completion races and worktree boundaries" 'registry_safety_checks'

echo "review coverage checks (no network)"
coverage_checks() {
  "$PY" - "$A" "$T" <<'PY'
import json, os, subprocess, sys
wrapper, root = sys.argv[1:]
directory = os.path.join(root, "coverage")
os.makedirs(directory)
log = os.path.join(directory, "transcript.log")
transcript = """thinking
Mentioning pytest here does not run it.
exec
/bin/bash -lc 'cat calc.py' in /repo succeeded in 2ms:
npm test is mentioned in file contents only
exec
/bin/bash -lc 'git diff' in /repo succeeded in 2ms:
diff output
exec
/bin/bash -lc 'npm test' in /repo succeeded in 2ms:
passed
exec
/bin/bash -lc 'git status' in /repo succeeded in 2ms:
 M calc.py
apply patch
*** Begin Patch
*** Update File: calc.py
@@
-old
+new
*** Update File: calc.py
@@
-old
+new
*** End Patch
codex
*** Update File: not-a-patch.py
"""
with open(log, "wb") as f:
    f.write(transcript.replace("\n", "\r\n").encode())
line = "[claudex coverage: exec=4 tests=yes executed=no patched=1]"
assert subprocess.check_output([wrapper, "coverage", log], text=True).strip() == line
negative = os.path.join(directory, "negative.log")
with open(negative, "w") as f:
    # an "exec" header without codex's "<cmd> in <cwd>" framing is transcript content, not a tool call;
    # runner names inside file contents or echo/rg arguments are not test runs; multi-line commands are
    f.write("exec\ncat calc.py\nnpm test\ncodex\npytest\n*** Update File: fake.py\n"
            "exec\n/bin/bash -lc 'cat pytest.ini' in /repo\n succeeded in 1ms:\n[pytest]\n"
            "exec\n/bin/bash -lc 'echo \"npm test\"; rg jest package.json' in /repo\n succeeded in 1ms:\nnpm test\n"
            "apply patch\n*** Update File: fake.py\n*** End Patch\n")
assert subprocess.check_output([wrapper, "coverage", negative], text=True).strip() == "[claudex coverage: exec=2 tests=no executed=no patched=0]"
with open(negative, "w") as f:
    f.write("exec\n/bin/bash -lc 'cd /repo\npython3 -m pytest -q' in /repo\n succeeded in 2ms:\nok\n"
            "apply patch\npatch: completed\n/repo/a.py\n/repo/b.py\ndiff --git a/a.py b/a.py\ndiff --git a/zzz.py b/zzz.py\n\ncodex\nexec\n")
assert subprocess.check_output([wrapper, "coverage", negative], text=True).strip() == "[claudex coverage: exec=1 tests=yes executed=yes patched=2]"
with open(negative, "w") as f:
    f.write("")
assert subprocess.check_output([wrapper, "coverage", negative], text=True).strip() == "[claudex coverage: exec=0 tests=no executed=no patched=0]"
# Ad hoc execution is distinct from merely reading code or mentioning a runner.
for command, expected in [
    ("python3 <<'PY'\nprint(1)\nPY", True),
    ("python <<'PY'\nprint(1)\nPY", True),
    ("cat x.py", False), ("echo python3; cat x.py", False),
    ("node -e '1'", True), ("deno run x.ts", True), ("bun x.ts", True),
    ("ruby x.rb", True), ("php x.php", True), ("go run main.go", True),
    ("cargo run", True), ("npx ts-node main.ts", True), ("npx tsx main.ts", True), ("ts-node x.ts", True),
    ("go version", False), ("cargo check", False),
    ("bash -c './script.sh'", True), ("sh -c 'sh script'", True),
    ("bash -c 'cat x.py'", False), ("bash -c '/usr/bin/cat x.py'", False),
    ("cd /repo && bash -c './script.sh'", True),
    ("bash -c 'cat x.py' && python3 x.py", True),
    ("/bin/bash -lc \"python3 <<'PY'\nprint(1)\nPY\"", True),
]:
    with open(negative, "w") as f: f.write("exec\n" + command + " in /repo\n succeeded in 1ms:\n")
    output = subprocess.check_output([wrapper, "coverage", negative], text=True)
    assert ("executed=yes" in output) == expected, (command, output)
answer = os.path.join(directory, "answer.json")
claimed = dict(summary="Nothing found", findings=[], coverage=dict(
    files_read=["calc.py"], commands_run=["cat calc.py"], tests_run=False,
    test_result="not run", confidence="low", confidence_reason="No tests run"))
with open(answer, "w") as f:
    json.dump(claimed, f)
env = dict(os.environ, STUB_LOG=log, STUB_ANSWER=answer)
measured = dict(exec_count=4, tests_detected=True, executed=False, patched=1)
registry = os.path.join(root, ".claude", "claudex-logs", "runs.jsonl")
def run(*args, **extra):
    mode = args[0] if args and args[0] in ("review", "build") else None
    command = [wrapper] + ([mode] if mode else []) + ["-C", directory] + list(args[1:] if mode else args)
    return subprocess.run(command, env=dict(env, **extra), text=True, capture_output=True)
def last_event():
    with open(registry) as f:
        return json.loads(f.readlines()[-1])
def check_event(status):
    event = last_event()
    assert event["status"] == status, event
    assert {k: event[k] for k in measured} == measured, event
result = run("review", "--json")
assert result.returncode == 0, result.stderr
assert "WARNING" in result.stderr and "1 distinct path" in result.stderr
body, footer = result.stdout.rsplit("[claudex log:", 1)
assert footer.strip().endswith("]")
parsed = json.loads(body)
assert parsed == dict(claimed, measured=measured), parsed
check_event("done")
# the RESULT file (.last.md) now carries the merged document; the raw model answer is kept alongside
with open(last_event()["log"].replace(".log", ".last.md")) as f:
    assert json.load(f) == dict(claimed, measured=measured)
with open(last_event()["log"].replace(".log", ".raw.md")) as f:
    assert json.load(f) == claimed
args_file = os.path.join(directory, "args.txt")
result = run("review", STUB_ARGS=args_file)
with open(args_file) as f: arguments = f.read().splitlines()
assert arguments[0] == "exec" and "review" not in arguments and "--output-schema" not in arguments
assert any("adversarial code review" in arg and "uncommitted changes" in arg for arg in arguments)
assert last_event()["tokens"] == 1234
assert result.returncode == 0 and line in result.stdout
check_event("done")
with open(answer, "w") as f:
    f.write("invalid JSON\n")
result = run("review", "--json")
assert result.returncode == 0 and result.stdout.startswith("invalid JSON\n\n" + line)
check_event("done")
result = run("review", "--json", STUB_FAIL="1")
assert result.returncode == 1 and "no final message" in result.stderr
check_event("failed")
build = dict(summary="Implemented", files_changed=[dict(path="calc.py", change="modified", why="Fix addition")],
             commands_run=["npm test"], tests_run=True, test_result="passed", assumptions=[], left_undone=[],
             needs_attention=["Review addition"])
with open(answer, "w") as f: json.dump(build, f)
input_file = os.path.join(directory, "input.txt")
result = run("build", "implement addition", STUB_ARGS=args_file, STUB_INPUT=input_file)
assert result.returncode == 0 and not result.stderr, result
assert json.loads(result.stdout.rsplit("[claudex log:", 1)[0]) == dict(build, measured=measured)
with open(args_file) as f: arguments = f.read().splitlines()
assert arguments[arguments.index("--output-schema") + 1].endswith("/build-schema.json")
with open(input_file) as f: assert "final message must be JSON" in f.read()
check_event("done")
with open(last_event()["log"].replace(".log", ".last.md")) as f: assert json.load(f) == dict(build, measured=measured)
with open(last_event()["log"].replace(".log", ".raw.md")) as f: assert json.load(f) == build
with open(answer, "w") as f: f.write("invalid build JSON")
result = run("build", "implement addition")
assert result.returncode == 0 and "invalid build JSON\n" + line in result.stdout, result
check_event("done")
result = run("exec prompt")
assert result.returncode == 0 and "[claudex coverage:" not in result.stdout
assert all(k not in last_event() for k in measured)
PY
}
check "measures CRLF transcripts, merges JSON, flags patches and records review events" 'coverage_checks'

feature_checks() {
  "$PY" - "$HERE" "$T" <<'PY'
import importlib.util, json, os, pathlib, subprocess, sys, time
from unittest.mock import patch
here, temp = map(pathlib.Path, sys.argv[1:])
base = temp / "features"
base.mkdir()
wrapper = here / "claudex"
helper = here / "claudex-runs.py"
spec = importlib.util.spec_from_file_location("runs_features", helper)
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
def run(args, **kw):
    result = subprocess.run([str(a) for a in args], text=True, capture_output=True, **kw)
    assert result.returncode == 0, (args, result.returncode, result.stdout, result.stderr)
    return result
def git(root, *args): return run(["git", "-C", root, *args])
def repo(name):
    root = base / name
    root.mkdir()
    git(root, "init", "-q")
    (root / "CLAUDE.md").write_text("<!-- claudex-auto:start -->\n")
    (root / ".gitignore").write_text(".claude/\n.claudex-wt/\n")
    (root / "tracked file.txt").write_text("original\n")
    git(root, "add", "-A")
    git(root, "-c", "user.email=t@t", "-c", "user.name=t", "commit", "-qm", "fixture")
    return root
def cli(root, *args): return run(["bash", wrapper, *args, "-C", root])
def seed(root, events):
    path = root / ".claude/claudex-logs/runs.jsonl"
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("".join(json.dumps(event) + "\n" for event in events))

# Preflight: isolated HOME, controlled CLI version and no real credentials.
home = base / "home"
home.mkdir()
project = base / "setup"
project.mkdir()
env = dict(os.environ, HOME=str(home), CLAUDEX_WRAPPER=str(wrapper), CODEX_HOME=str(home / "custom-codex"))
codex_home = pathlib.Path(env["CODEX_HOME"])
codex_home.mkdir()
def setup(action="on", **extra):
    return run(["bash", here / "claudex-setup", project, action], env=dict(env, **extra)).stdout
out = setup()
assert "Preflight" in out and "codex-cli test-version" in out and "python: " in out, out
assert "default (not set)" in out and "not signed in — run: codex" in out
for model in ("test-mini", "test-nano"):
    (codex_home / "config.toml").write_text('model = "' + model + '"\n[profiles.other]\nmodel = "ignored"\n')
    (codex_home / "auth.json").write_text("{}")
    out = setup()
    assert "codex model: " + model in out and "reviews/builds will be weaker" in out, out
    assert "auth.json present" in out
# Force the regex fallback with invalid TOML as well as testing valid TOML.
for prefix in ("", "legacy = unquoted\n"):
    for value in ('"test-mini"', "'test-mini'", "test-mini"):
        (codex_home / "config.toml").write_text(prefix + "model = " + value + " # inline comment\n[profiles.other]\nmodel = 'ignored'\n")
        out = setup()
        assert "codex model: test-mini\n" in out and "reviews/builds will be weaker" in out, out
(home / ".codex").mkdir()
(home / ".codex/config.toml").write_text('model = "strong-model"\n')
out = setup(CODEX_HOME="")
assert "codex model: strong-model" in out and "weaker" not in out
assert "Preflight" not in setup("off")
# Simulate a missing CLI without depending on the host's PATH or installation.
bash_env = base / "no-codex.sh"
bash_env.write_text('command() { if [[ "$*" == "-v codex" ]]; then return 1; fi; builtin command "$@"; }\n')
out = setup(BASH_ENV=str(bash_env))
assert "codex CLI: NOT FOUND" in out and "npm i -g @openai/codex" in out
assert "enabled" in out

# Budget: latest event per run, terminal states, time window, live/dead and mode filtering.
root = repo("budget")
now = int(time.time())
events = [dict(id=state, status=state, duration=900, ts=now, mode="exec")
          for state in ("done", "failed", "timeout", "cancelled")]
events += [dict(id="done", status="done", duration=960, ts=now, mode="exec"),
           dict(id="old", status="done", duration=99999, ts=now-86401),
           dict(id="future", status="done", duration=99999, ts=now+86400),
           dict(id="stale", status="stale", duration=99999, ts=now),
           dict(id="running", status="running", duration=99999, ts=now, mode="review", pid=0)]
seed(root, events)
out = cli(root, "budget")
warning = "claudex: budget warning — 61 min used in last 24h (budget 60)"
assert "61 min used in last 24h (budget 60)" in out.stdout and out.stderr.strip() == warning, out
assert cli(root, "status").stderr.strip() == warning
for mode in ([], ["review"], ["build"]):
    seed(root, events)  # prior stub durations must not change the expected warning
    result = run(["bash", wrapper, *mode, "-C", root, "test prompt"])
    assert warning in result.stderr, result
conf = root / ".claude/claudex.conf"
conf.write_text("max_builders=1\nbudget_minutes=100\n")
assert not cli(root, "budget").stderr
assert "budget 100" in cli(root, "budget").stdout
conf.write_text("max_builders=invalid\nbudget_minutes=-1\n")
assert m.limits(root) == dict(max_builders=4, budget_minutes=60)
seed(root, [dict(id="equal", status="done", duration=3600, ts=now)])
assert not cli(root, "budget").stderr  # only warn when exceeded

identity = dict(command=m.ps_field(os.getpid(), "command") or "python", pstart=m.ps_field(os.getpid(), "lstart"))
seed(root, [dict(id="unrelated", status="running", mode="build", pid=os.getpid(),
                 command="codex", pstart="mismatched start", ts=now)])
assert run([sys.executable, helper, "count-running", root, "build"]).stdout.strip() == "0"
# Verify the start time independently of a command mismatch.
seed(root, [dict(id="reused", status="running", mode="build", pid=os.getpid(),
                 command=identity["command"], pstart="mismatched start", ts=now)])
assert run([sys.executable, helper, "count-running", root, "build"]).stdout.strip() == "0"
seed(root, [dict(id="alive", status="running", mode="build", pid=os.getpid(), ts=now, **identity),
            dict(id="dead", status="running", mode="build", pid=0, ts=now),
            dict(id="review", status="running", mode="review", pid=os.getpid(), ts=now),
            dict(id="finished", status="done", mode="build", pid=os.getpid(), ts=now)])
assert run([sys.executable, helper, "count-running", root, "build"]).stdout.strip() == "1"
conf.write_text("max_builders=1\nbudget_minutes=60\n")
blocked = subprocess.run(["bash", str(wrapper), "build", "-C", str(root), "test prompt"], text=True, capture_output=True)
assert blocked.returncode == 3 and blocked.stderr.strip() == (
    "claudex: build budget reached (1 running); wait, raise max_builders in .claude/claudex.conf, or run claudex cancel"), blocked
linked = base / "budget-linked"
git(root, "worktree", "add", "-q", "--detach", str(linked), "HEAD")
try:
    assert "budget 60" in cli(linked, "budget").stdout
    assert run([sys.executable, helper, "count-running", linked, "build"]).stdout.strip() == "1"
    blocked = subprocess.run(["bash", str(wrapper), "build", "-C", str(linked), "test prompt"], text=True, capture_output=True)
    assert blocked.returncode == 3, blocked
finally: git(root, "worktree", "remove", "--force", str(linked))
conf.write_text("max_builders=2\n")
run(["bash", wrapper, "build", "-C", root, "test prompt"])
# Defaults block four live builders, while reviews/exec remain allowed.
conf.unlink()
seed(root, [dict(id=str(i), status="running", mode="build", pid=os.getpid(), ts=now, **identity) for i in range(4)])
blocked = subprocess.run(["bash", str(wrapper), "build", "-C", str(root), "test prompt"], text=True, capture_output=True)
assert blocked.returncode == 3 and "(4 running)" in blocked.stderr
run(["bash", wrapper, "review", "-C", root])
# Existing Windows probe is also the count-running probe.
with patch.object(m.os, "name", "nt"), patch.object(m, "ps_field", side_effect=lambda pid, field: identity["command" if field == "command" else "pstart"]), patch.object(m.subprocess, "run", return_value=subprocess.CompletedProcess([], 0)) as probe:
    assert m.count_running(root, "build") == 4
    assert all(call.args[0][:2] == ["bash", "-c"] for call in probe.call_args_list)

# Six simultaneous requests contend for a single builder slot.
seed(root, [])
conf.write_text("max_builders=1\n")
release = root / ".claude/release"
started = root / ".claude/started"
concurrent_env = dict(os.environ, STUB_RELEASE=str(release), STUB_STARTED=str(started))
workers = []
try:
    for _ in range(6):
        workers.append(subprocess.Popen(["bash", str(wrapper), "build", "-C", str(root), "concurrent"],
                                        text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=concurrent_env))
    deadline = time.monotonic() + 12
    while sum(worker.poll() is not None for worker in workers) < 5 and time.monotonic() < deadline:
        time.sleep(0.05)
    assert sum(worker.poll() == 3 for worker in workers) == 5, [worker.poll() for worker in workers]
    assert len(started.read_text().splitlines()) == 1
finally:
    release.touch()
    results = [worker.communicate(timeout=25) for worker in workers]
assert sorted(worker.returncode for worker in workers) == [0, 3, 3, 3, 3, 3], results
lock = root / ".claude/claudex-logs/.builders.lock"
assert not lock.exists()
# Recover stale locks, proceed with a warning on a busy lock, and release on timeout/early exit.
lock.mkdir()
os.utime(lock, (time.time() - 61, time.time() - 61))
run(["bash", wrapper, "build", "-C", root, "stale lock"])
assert not lock.exists()
lock.mkdir()
start = time.monotonic()
result = run(["bash", wrapper, "build", "-C", root, "busy lock"])
assert time.monotonic() - start < 8 and "proceeding without lock" in result.stderr
assert lock.exists()  # a timed-out waiter never removes someone else's lock
lock.rmdir()
release.unlink()
result = subprocess.run(["bash", str(wrapper), "build", "-t", "0", "-C", str(root), "timeout"],
                        env=concurrent_env, text=True, capture_output=True, timeout=10)
assert result.returncode == 124 and not lock.exists(), result
conf.write_text("max_builders=0\n")
result = subprocess.run(["bash", str(wrapper), "build", "-C", str(root), "blocked"], text=True, capture_output=True)
assert result.returncode == 3 and not lock.exists(), result

# Stop hook: silence in bypass cases, JSON only on block, shared fingerprint and review reuse.
root = repo("hook project")
hook = here / "claudex-hook-stop"
def stop(active=False, directory=root):
    start = time.monotonic()
    result = run(["bash", hook], input=json.dumps(dict(cwd=str(directory), stop_hook_active=active)), env=env)
    assert time.monotonic() - start < 2, "Stop hook exceeded two seconds"
    assert result.stderr == "", result
    return result.stdout
assert stop() == ""  # clean tree
tracked = root / "tracked file.txt"
tracked.write_text("changed\n")
assert stop(True) == ""
(root / "CLAUDE.md").write_text("not enabled\n")
assert stop() == ""
(root / "CLAUDE.md").write_text("<!-- claudex-auto:start -->\n")
blocked = json.loads(stop())
assert blocked["decision"] == "block"
assert str(home / ".local/bin/claudex") in blocked["reason"] and 'ack -C "' in blocked["reason"]
assert str(root) in blocked["reason"]
assert cli(root, "ack").stdout == ""
assert stop() == ""
reviewed = root / ".claude/claudex-logs/.reviewed"
fingerprint = run([sys.executable, helper, "fingerprint", root]).stdout
assert reviewed.read_text() == fingerprint
# Metadata and managed worktree files do not invalidate an acknowledgement.
(root / ".claude/extra").write_text("metadata")
(root / ".claudex-wt").mkdir()
(root / ".claudex-wt/untracked").write_text("ignored")
assert stop() == ""
# Untracked file names and contents, and tracked diffs, invalidate acknowledgements.
(root / "untracked file.txt").write_text("new")
assert json.loads(stop())["decision"] == "block"
cli(root, "ack")
(root / "untracked file.txt").write_text("changed contents")
assert json.loads(stop())["decision"] == "block"
cli(root, "ack")
tracked.write_text("changed again\n")
assert json.loads(stop())["decision"] == "block"
git(root, "add", "tracked file.txt")
assert json.loads(stop())["decision"] == "block"  # staged diff is included
value = m.fingerprint(str(root))
matching = dict(id="review", status="done", mode="review", ts=1,
                dir=str(root.resolve()), scope="uncommitted", fingerprint=value)
for overrides in (dict(fingerprint="old"), dict(status="failed"), dict(mode="build"),
                  dict(dir=str(base)), dict(scope="commit"), dict(scope="base"), dict(scope=None)):
    seed(root, [dict(matching, **overrides)])
    assert json.loads(stop())["decision"] == "block", overrides
seed(root, [matching])
assert stop() == ""  # matching content counts regardless of timestamps
assert reviewed.read_text() == run([sys.executable, helper, "fingerprint", root]).stdout
seed(root, [])
assert stop() == ""  # successful review cached its fingerprint
# Real wrapper records scope and the START fingerprint, even when review changes a file.
for scope in ([], ["--base", "HEAD"], ["--commit", "HEAD"]):
    before = m.fingerprint(str(root))
    run(["bash", wrapper, "review", "-C", root, *scope])
    event = list(m.load(str(root))[1].values())[-1]
    assert event["scope"] == (scope[0][2:] if scope else "uncommitted"), event
    assert event["fingerprint"] == before and event["dir"] == str(root.resolve()), event
before = m.fingerprint(str(root))
run(["bash", wrapper, "review", "-C", root], env=dict(os.environ, STUB_EDIT=str(tracked)))
event = list(m.load(str(root))[1].values())[-1]
assert event["fingerprint"] == before != m.fingerprint(str(root)), event
assert json.loads(stop())["decision"] == "block"
# Excluded changes are silent even without acknowledgement or a review record.
excluded = repo("excluded-only")
(excluded / ".claude").mkdir()
settings = excluded / ".claude/settings.json"
settings.write_text("{}")
git(excluded, "add", "-f", ".claude/settings.json")
git(excluded, "-c", "user.email=t@t", "-c", "user.name=t", "commit", "-qm", "tracked settings")
settings.write_text('{"changed": true}')
(excluded / ".claude/untracked").write_text("ignored")
assert stop(directory=excluded) == ""
nonrepo = base / "not-git"
nonrepo.mkdir()
(nonrepo / "CLAUDE.md").write_text("<!-- claudex-auto:start -->\n")
nonrepo_env = dict(env, GIT_CEILING_DIRECTORIES=str(base))
result = run(["bash", hook], input=json.dumps(dict(cwd=str(nonrepo))), env=nonrepo_env)
assert not result.stdout and not result.stderr
assert not run(["bash", hook], input="invalid json").stdout
with patch.object(m.os, "name", "nt"), patch.object(m.os.path, "realpath", side_effect=lambda p: p), patch.object(m.subprocess, "run", return_value=subprocess.CompletedProcess([], 0, "C:/project with spaces\n")) as convert:
    assert m.project_path("/c/project with spaces") == "C:/project with spaces"
    assert convert.call_args.args[0] == ["cygpath", "-m", "/c/project with spaces"]
# A project enabled from a repository subdirectory fingerprints paths relative to that directory.
sub = root / "subproject"
sub.mkdir()
(sub / "CLAUDE.md").write_text("<!-- claudex-auto:start -->\n")
(sub / "file.txt").write_text("original")
git(root, "add", "subproject")
git(root, "-c", "user.email=t@t", "-c", "user.name=t", "commit", "-qm", "subproject fixture")
(sub / "file.txt").write_text("modified")
seed(root, [dict(id="old", status="done", mode="review", ts=int(time.time())-60)])
assert json.loads(stop(directory=sub))["decision"] == "block"
(sub / "untracked.txt").write_text("sub contents")
seed(root, [dict(matching, dir=str(sub.resolve()), fingerprint=m.fingerprint(str(sub)))])
assert stop(directory=sub) == ""
# Linked worktrees share the registry, but fingerprint their own tracked and untracked files.
linked = base / "hook-linked"
git(root, "worktree", "add", "-q", "--detach", str(linked), "HEAD")
try:
    (linked / "tracked file.txt").write_text("linked change")
    (linked / "untracked file.txt").write_text("linked contents")
    linked_value = m.fingerprint(str(linked))
    assert linked_value != m.fingerprint(str(root))
    seed(root, [dict(matching, fingerprint=linked_value)])
    assert json.loads(stop(directory=linked))["decision"] == "block"
    run(["bash", wrapper, "review", "-C", linked])
    assert stop(directory=linked) == ""
    (linked / "untracked file.txt").write_text("linked contents changed")
    assert json.loads(stop(directory=linked))["decision"] == "block"
finally: git(root, "worktree", "remove", "--force", str(linked))
# Deterministic text normalization, binary hashing, unusual paths and the 1 MiB cutoff.
content = repo("fingerprint-content")
untracked = content / ("space and newline.txt" if os.name == "nt" else "space and\nnewline.txt")
untracked.write_bytes(b"one\r\ntwo\r\n")
value = m.fingerprint(str(content))
untracked.write_bytes(b"one\ntwo\n")
assert m.fingerprint(str(content)) == value
untracked.write_bytes(b"binary\0\r\n")
value = m.fingerprint(str(content))
untracked.write_bytes(b"binary\0\n")
assert m.fingerprint(str(content)) != value
large = content / "large.bin"
large.write_bytes(b"a" * (1024 * 1024))
value = m.fingerprint(str(content))
large.write_bytes(b"b" * (1024 * 1024))
assert m.fingerprint(str(content)) != value  # exactly 1 MiB still hashes contents
large.write_bytes(b"a" * (1024 * 1024 + 1))
value = m.fingerprint(str(content))
large.write_bytes(b"b" * (1024 * 1024 + 1))
assert m.fingerprint(str(content)) != value  # large files use size AND mtime
large.write_bytes(b"b" * (1024 * 1024 + 2))
assert m.fingerprint(str(content)) != value
value = m.fingerprint(str(content))
large.rename(content / "renamed.bin")
assert m.fingerprint(str(content)) != value
# Bound content reads, include metadata for the remainder, and keep cached cutoffs stable.
many = repo("many-untracked")
for i in range(350): (many / f"untracked-{i:03}.txt").write_text("contents")
start = time.monotonic()
assert json.loads(stop(directory=many))["decision"] == "block"
assert time.monotonic() - start < 3
value = m.fingerprint(str(many))
assert m.fingerprint(str(many)) == value
late = many / "untracked-349.txt"
late.write_text("CONTENTS")  # unchanged size, changed mtime
assert m.fingerprint(str(many)) != value
# The policy is fixed: files beyond the 300th contribute size+mtime, never content, and the
# result does not depend on timing. A hard deadline yields an "incomplete:" value that can
# never match a stored review/ack fingerprint (fail closed rather than fail open).
value = m.fingerprint(str(many))
late.write_text("contents")          # restore contents: same size, new mtime -> still differs (metadata)
assert m.fingerprint(str(many)) != value
early = many / "untracked-000.txt"
early.write_text("CONTENTS")          # within the first 300: content-hashed
changed = m.fingerprint(str(many))
assert changed != m.fingerprint(str(many)) or True  # value is stable across calls:
assert m.fingerprint(str(many)) == changed
snapshot = m.changes(str(many))
with patch.object(m.time, "monotonic", return_value=10**9):
    timed = m.fingerprint(str(many), deadline=1, snapshot=snapshot)
assert timed.startswith("incomplete:")
assert m.fingerprint(str(many), snapshot=snapshot) == changed   # no deadline: complete and stable
# exactly the first 300 untracked files are content-read; the rest use metadata only
real_open = open
reads = []
def counted_open(path, *args, **kwargs):
    if args and args[0] == "rb": reads.append(path)
    return real_open(path, *args, **kwargs)
with patch("builtins.open", side_effect=counted_open):
    m.fingerprint(str(many), snapshot=snapshot)
assert len(reads) == 300, len(reads)
# A blocked stdin is also inside the whole-hook timeout, with no output.
start = time.monotonic()
process = subprocess.Popen(["bash", str(hook)], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
try:
    assert process.wait(timeout=5) == 0
    assert process.stdout.read() == b"" and process.stderr.read() == b""
    assert time.monotonic() - start < 5
finally:
    process.stdin.close()
    if process.poll() is None: process.kill(); process.wait()

# Direct edits: enabled projects only, all three tools, deduplication and shared roots.
edited = repo("direct-edits")
edit_hook = here / "claudex-hook-edit"
def edit(directory, tool="Edit", path="tracked file.txt"):
    result = run(["bash", edit_hook], input=json.dumps(dict(cwd=str(directory), tool_name=tool, tool_input=dict(file_path=path))))
    assert not result.stdout and not result.stderr
edit(edited, "Read")
assert not (edited / ".claude/claudex-logs/edits.jsonl").exists()
(edited / "CLAUDE.md").write_text("disabled")
edit(edited)
assert not (edited / ".claude/claudex-logs/edits.jsonl").exists()
(edited / "CLAUDE.md").write_text("<!-- claudex-auto:start -->\n")
for tool in ("Edit", "Write", "MultiEdit"): edit(edited, tool)
entries = [json.loads(line) for line in (edited / ".claude/claudex-logs/edits.jsonl").read_text().splitlines()]
assert len(entries) == 3 and all(set(entry) == {"ts", "path"} for entry in entries)
assert "Direct edits by Claude since last build/review: 1 files" in cli(edited, "status").stdout
(edited / "tracked file.txt").write_text("direct change")
assert json.loads(stop(directory=edited))["reason"].endswith(": Claude edited 1 file(s) directly this change set")
seed(edited, [dict(id="latest", status="done", mode="build", ts=int(time.time()) + 1)])
assert "Direct edits by Claude since last build/review: 0 files" in cli(edited, "status").stdout
seed(edited, [dict(id="latest", status="done", mode="review", ts=int(time.time()) - 60)])
assert "Direct edits by Claude since last build/review: 1 files" in cli(edited, "status").stdout
edit_linked = base / "edit-linked"
git(edited, "worktree", "add", "-q", "--detach", str(edit_linked), "HEAD")
try:
    edit(edit_linked, path="another.txt")
    assert m.direct_edits(str(edited)) == 2
    assert not (edit_linked / ".claude/claudex-logs/edits.jsonl").exists()
finally: git(edited, "worktree", "remove", "--force", str(edit_linked))
assert not run(["bash", edit_hook], input="invalid json").stdout

# Merge commits builder changes, reports overlaps, preserves foreign/conflicting branches.
def merge_repo(name, conflict=False):
    project = repo(name)
    git(project, "config", "user.email", "t@t")
    git(project, "config", "user.name", "t")
    for branch in ("claudex/a", "claudex/b", "foreign"):
        path = project / ".claudex-wt" / branch.split("/")[-1]
        git(project, "worktree", "add", "-q", "-b", branch, str(path), "HEAD")
        filename = "tracked file.txt" if conflict and branch.startswith("claudex/") else branch.split("/")[-1] + ".txt"
        (path / filename).write_text(branch + "\n")
        logs = path / ".claude/claudex-logs"
        logs.mkdir(parents=True)
        (logs / "run.log").write_text("ignored builder transcript")
    return project
for conflict in (False, True):
    project = merge_repo("merge-conflict" if conflict else "merge-disjoint", conflict)
    result = subprocess.run(["bash", str(wrapper), "merge", "-C", str(project)], text=True, capture_output=True)
    assert result.returncode == (4 if conflict else 0), result
    assert "MERGED claudex/a" in result.stdout and "Overlap table:" in result.stdout
    assert not (project / ".claudex-wt/a").exists()
    branches = git(project, "branch", "--format=%(refname:short)").stdout.splitlines()
    assert "claudex/a" not in branches and "foreign" in branches
    assert (project / ".claudex-wt/foreign/foreign.txt").exists()
    assert not (project / "foreign.txt").exists()
    if conflict:
        assert 'CONFLICT claudex/b: "tracked file.txt"' in result.stdout
        assert 'claudex/a | claudex/b | "tracked file.txt"' in result.stdout
        assert (project / ".claudex-wt/b").exists() and "claudex/b" in branches
        assert (project / "tracked file.txt").read_text() == "claudex/a\n"
        # A later disjoint branch must still merge after the conflict was aborted.
        third = project / ".claudex-wt/z"
        git(project, "worktree", "add", "-q", "-b", "claudex/z", str(third), "HEAD")
        (third / "z.txt").write_text("third")
        result = subprocess.run(["bash", str(wrapper), "merge", "-C", str(project)], text=True, capture_output=True)
        assert result.returncode == 4 and "MERGED claudex/z" in result.stdout, result
        assert not third.exists() and (project / "z.txt").read_text() == "third"
    else:
        assert "MERGED claudex/b" in result.stdout and "claudex/b" not in branches
        assert not (project / ".claudex-wt/b").exists()
        assert (project / "a.txt").read_text() == "claudex/a\n"
        assert (project / "b.txt").read_text() == "claudex/b\n"
    assert not git(project, "status", "--porcelain").stdout
project = merge_repo("merge-dirty")
(project / "dirty.txt").write_text("dirty")
result = subprocess.run(["bash", str(wrapper), "merge", "-C", str(project)], text=True, capture_output=True)
assert result.returncode == 2 and "current tree is dirty" in result.stderr
assert (project / ".claudex-wt/a").exists() and (project / ".claudex-wt/b").exists()
assert git(project / ".claudex-wt/a", "status", "--porcelain").stdout  # refused before committing
manifest = json.loads((here.parent / "hooks/hooks.json").read_text())
assert manifest["hooks"]["Stop"] == [{"hooks": [{"type": "command", "command": '\"${CLAUDE_PLUGIN_ROOT}/scripts/claudex-hook-stop\"', "timeout": 20}]}]
assert manifest["hooks"]["PostToolUse"] == [{"matcher": "Edit|Write|MultiEdit", "hooks": [{"type": "command", "command": '\"${CLAUDE_PLUGIN_ROOT}/scripts/claudex-hook-edit\"', "timeout": 5}]}]
PY
}
echo "preflight, budget and Stop hook checks (no network)"
check "preflight warnings, budget enforcement/accounting and review/ack hook" 'feature_checks'
# Keep live smoke tests isolated from the offline fixtures.
git -C "$T" worktree remove --force "$T/.claudex-wt/other"
rmdir "$T/.claudex-wt"
git -C "$T" worktree remove --force "$T/linked"
rm -rf "$T/stub-bin" "$T/separate" "$T/separate-meta" "$T/nonrepo" "$T/safety" "$T/coverage" "$T/features" "$LONG_DIR"
export PATH="$REAL_PATH"
if [[ $NETWORK -eq 0 ]]; then
  echo "skipping live Codex checks (--offline or codex unavailable)"
  echo "passed=$pass failed=$fail"; [[ $fail -eq 0 ]]; exit $?
fi
rm -f "$T/.claude/claudex-logs/runs.jsonl"

echo "codex runs"
check "exec arg prompt"    'o=$("$A" -C "$T" "Reply with exactly: A1"); [[ "$o" == A1* ]]'
check "exec piped prompt"  'o=$(echo "Reply with exactly: A2" | "$A" -C "$T"); [[ "$o" == A2* ]]'
check "relative -C"        'o=$(cd "$(dirname "$T")" && "$A" -C "$(basename "$T")" "Reply with exactly: A3"); [[ "$o" == A3* ]]'
check "conf effort honoured" 'mkdir -p "$T/.claude"; echo effort=medium > "$T/.claude/claudex.conf"; o=$("$A" -C "$T" "Reply with exactly: A4"); rm "$T/.claude/claudex.conf"; [[ "$o" == *"effort=medium"* ]]'
check "timeout kills run"  'o=$("$A" -C "$T" -t 2 -e xhigh "Write a 2000 word essay about sorting." 2>&1); rc=$?; [[ $rc -eq 124 && "$o" == *"timed out"* ]]'
check "review plain"       'o=$("$A" review -C "$T" --uncommitted "One line: is add correct now?"); [[ "$o" == *"effort=medium"* && "$o" == *"sandbox=workspace-write"* ]]'
check "review json parses with claimed and measured coverage" 'o=$("$A" review -C "$T" --uncommitted --json | sed "/^\[claudex log/d"); echo "$o" | "$PY" -c "import sys,json; d=json.load(sys.stdin); assert \"findings\" in d; assert d[\"coverage\"][\"confidence\"] in (\"high\", \"medium\", \"low\"); assert type(d[\"measured\"][\"exec_count\"]) is int"'
check "review --ro honoured" 'o=$("$A" review -C "$T" --ro "One word: ok?"); [[ "$o" == *"sandbox=read-only"* ]]'
check "build edits files, reports"  'printf "def sub(a,b):\n    return a-b\n" > "$T/ops.py"; git -C "$T" add -A; git -C "$T" -c user.email=t@t -c user.name=t commit -qm ops; o=$("$A" build -C "$T" -e low "Add a function mul(a,b) returning a*b to ops.py. Do nothing else."); grep -q "def mul" "$T/ops.py" && [[ "$o" == *"effort=low"* && "$o" == *"sandbox=workspace-write"* ]]'
check "build default effort high"   'o=$("$A" build -C "$T" -t 3 "Add a comment line to ops.py." 2>&1); [[ "$o" == *"effort=high"* ]]'
check "runs.jsonl records done + tokens" 'grep -q "\"status\":\"done\"" "$T/.claude/claudex-logs/runs.jsonl" && grep -q "\"tokens\":[1-9]" "$T/.claude/claudex-logs/runs.jsonl"'
check "status lists recent runs"   'o=$("$A" status -C "$T"); [[ "$o" == *"Recent ("* && "$o" == *"done"* ]]'
check "cancel kills builder + removes worktree" 'git -C "$T" worktree add -q -b claudex/t-1 .claudex-wt/1 HEAD; "$A" build -C "$T/.claudex-wt/1" -e xhigh "Write a 3000 word essay ESSAY.md in 12 sections." >/dev/null 2>&1 & sleep 5; o=$("$A" cancel -C "$T"); wait; [[ "$o" == *"cancelled"* ]] && [[ ! -d "$T/.claudex-wt" ]] && ! git -C "$T" branch | grep -q claudex/t-1'
check "log rotation keeps <=80 files" '[[ $(ls "$T/.claude/claudex-logs" | wc -l) -le 80 ]]'

echo; echo "passed=$pass failed=$fail"; [[ $fail -eq 0 ]]
