#!/usr/bin/env bash
# Smoke test against a throwaway repo. Use --offline to skip logged-in Codex checks.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"; A="$HERE/claudex"
PY="$(command -v python3 || command -v python)"
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
while [[ $# -gt 0 ]]; do
  if [[ "$1" == -o ]]; then
    if [[ "${STUB_FAIL:-0}" == 1 ]]; then :
    elif [[ -n "${STUB_ANSWER:-}" ]]; then cat "$STUB_ANSWER" > "$2"
    else printf 'stub answer\n' > "$2"; fi
    shift 2
  else shift; fi
done
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
line = "[claudex coverage: exec=4 tests=yes patched=1]"
assert subprocess.check_output([wrapper, "coverage", log], text=True).strip() == line
negative = os.path.join(directory, "negative.log")
with open(negative, "w") as f:
    # an "exec" header without codex's "<cmd> in <cwd>" framing is transcript content, not a tool call;
    # runner names inside file contents or echo/rg arguments are not test runs; multi-line commands are
    f.write("exec\ncat calc.py\nnpm test\ncodex\npytest\n*** Update File: fake.py\n"
            "exec\n/bin/bash -lc 'cat pytest.ini' in /repo\n succeeded in 1ms:\n[pytest]\n"
            "exec\n/bin/bash -lc 'echo \"npm test\"; rg jest package.json' in /repo\n succeeded in 1ms:\nnpm test\n"
            "apply patch\n*** Update File: fake.py\n*** End Patch\n")
assert subprocess.check_output([wrapper, "coverage", negative], text=True).strip() == "[claudex coverage: exec=2 tests=no patched=0]"
with open(negative, "w") as f:
    f.write("exec\n/bin/bash -lc 'cd /repo\npython3 -m pytest -q' in /repo\n succeeded in 2ms:\nok\n"
            "apply patch\npatch: completed\n/repo/a.py\n/repo/b.py\ndiff --git a/a.py b/a.py\ndiff --git a/zzz.py b/zzz.py\n\ncodex\nexec\n")
assert subprocess.check_output([wrapper, "coverage", negative], text=True).strip() == "[claudex coverage: exec=1 tests=yes patched=2]"
with open(negative, "w") as f:
    f.write("")
assert subprocess.check_output([wrapper, "coverage", negative], text=True).strip() == "[claudex coverage: exec=0 tests=no patched=0]"
answer = os.path.join(directory, "answer.json")
claimed = dict(summary="Nothing found", findings=[], coverage=dict(
    files_read=["calc.py"], commands_run=["cat calc.py"], tests_run=False,
    test_result="not run", confidence="low", confidence_reason="No tests run"))
with open(answer, "w") as f:
    json.dump(claimed, f)
env = dict(os.environ, STUB_LOG=log, STUB_ANSWER=answer)
measured = dict(exec_count=4, tests_detected=True, patched=1)
registry = os.path.join(root, ".claude", "claudex-logs", "runs.jsonl")
def run(*args, **extra):
    mode = args[0] if args and args[0] == "review" else None
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
result = run("review")
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
result = run("exec prompt")
assert result.returncode == 0 and "[claudex coverage:" not in result.stdout
assert all(k not in last_event() for k in measured)
PY
}
check "measures CRLF transcripts, merges JSON, flags patches and records review events" 'coverage_checks'
# Keep live smoke tests isolated from the offline fixtures.
git -C "$T" worktree remove --force "$T/.claudex-wt/other"
rmdir "$T/.claudex-wt"
git -C "$T" worktree remove --force "$T/linked"
rm -rf "$T/stub-bin" "$T/separate" "$T/separate-meta" "$T/nonrepo" "$T/safety" "$T/coverage" "$LONG_DIR"
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
