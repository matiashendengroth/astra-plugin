#!/usr/bin/env bash
# Smoke test for scripts/astra against a throwaway repo. Needs a logged-in codex.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"; A="$HERE/astra"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0; fail=0
ok()   { echo "  ✔ $1"; pass=$((pass+1)); }
bad()  { echo "  ✘ $1"; fail=$((fail+1)); }
check(){ if eval "$2"; then ok "$1"; else bad "$1"; fi; }

cd "$T" && git init -q && printf 'def add(a,b):\n    return a-b\n' > calc.py && git add -A && git -c user.email=t@t -c user.name=t commit -qm init
printf 'def add(a,b):\n    return a+b\n' > calc.py

echo "argument checks (no network)"
check "rejects bad effort"      '"$A" -e turbo x 2>&1 | grep -q "bad effort"'
check "rejects bad timeout"     '"$A" -t abc x 2>&1 | grep -q "bad timeout"'
check "rejects unknown option"  '"$A" --bogus x 2>&1 | grep -q "unknown option"'
check "rejects missing dir"     '"$A" -C /nonexistent x 2>&1 | grep -q "no such directory"'
check "no prompt, idle stdin exits fast" 'out=$( ( sleep 6 & exec "$A" -C "$T" ) 2>&1 ); echo "$out" | grep -q "no prompt"'

echo "codex runs"
check "exec arg prompt"    'o=$("$A" -C "$T" "Reply with exactly: A1"); [[ "$o" == A1* ]]'
check "exec piped prompt"  'o=$(echo "Reply with exactly: A2" | "$A" -C "$T"); [[ "$o" == A2* ]]'
check "relative -C"        'o=$(cd "$(dirname "$T")" && "$A" -C "$(basename "$T")" "Reply with exactly: A3"); [[ "$o" == A3* ]]'
check "conf effort honoured" 'mkdir -p "$T/.claude"; echo effort=medium > "$T/.claude/astra.conf"; o=$("$A" -C "$T" "Reply with exactly: A4"); rm "$T/.claude/astra.conf"; [[ "$o" == *"effort=medium"* ]]'
check "timeout kills run"  'o=$("$A" -C "$T" -t 2 -e xhigh "Write a 2000 word essay about sorting." 2>&1); rc=$?; [[ $rc -eq 124 && "$o" == *"timed out"* ]]'
check "review plain"       'o=$("$A" review -C "$T" --uncommitted "One line: is add correct now?"); [[ "$o" == *"effort=medium"* && "$o" == *"sandbox=workspace-write"* ]]'
check "review json parses" 'o=$("$A" review -C "$T" --uncommitted --json | sed "/^\[astra log/d"); echo "$o" | python3 -c "import sys,json; d=json.load(sys.stdin); assert \"findings\" in d"'
check "review --ro honoured" 'o=$("$A" review -C "$T" --ro "One word: ok?"); [[ "$o" == *"sandbox=read-only"* ]]'
check "log rotation keeps <=80 files" '[[ $(ls "$T/.claude/astra-logs" | wc -l) -le 80 ]]'

echo; echo "passed=$pass failed=$fail"; [[ $fail -eq 0 ]]
