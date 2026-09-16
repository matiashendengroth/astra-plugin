# CLAUDEX — Claude orchestrates, Codex builds

A [Claude Code](https://claude.com/claude-code) plugin that puts OpenAI Codex to work as a second, independent model inside your Claude Code sessions. Claude stays in charge: it classifies the task, writes the spec, runs Codex builders in parallel, merges the result, has Codex review the diff adversarially, and verifies every finding before reporting. You just give Claude the task.

```
you ─▶ Claude (orchestrator)
          ├─▶ CLAUDEX risk pass            (one-shot, on the plan)
          ├─▶ CLAUDEX builder ×N           (parallel, one git worktree each)
          ├─▶ merge · tests
          ├─▶ CLAUDEX adversarial review   (JSON findings: severity, file, line)
          └─▶ verify each finding · fix · report
```

Each CLAUDEX run appears as a named agent in Claude Code, and its full Codex transcript (commands, patches, test runs) is visible in that agent's view.

## Requirements

- Claude Code (desktop or terminal) on macOS, Linux, or Windows.
- [OpenAI Codex CLI](https://github.com/openai/codex): `npm i -g @openai/codex`, then run `codex` once to sign in.
- `git`, Python 3 (`python3` on macOS/Linux; `python` on Windows is fine).

### Windows notes
Claude Code runs bash commands through Git Bash, which the scripts target. Make sure:
- Git for Windows is installed (it ships Git Bash and `awk`, `sed`, `sort`).
- Python 3 is on PATH: `winget install Python.Python.3`.
- Codex is installed the same way: `npm i -g @openai/codex`, then `codex` to sign in.
The launcher installs to `%USERPROFILE%\.local\bin\claudex` and is invoked by its Git Bash path (`/c/Users/<you>/.local/bin/claudex`). Line endings are pinned to LF via `.gitattributes`, so a checkout with `core.autocrlf=true` still works.

## Install

```
/plugin marketplace add matiashendengroth/claudex
/plugin install claudex@gryd
```

Restart Claude Code so the plugin's commands load.

## Enable in a project

```
/claudex-auto
```

One command, idempotent. It installs a stable launcher at `~/.local/bin/claudex`, adds an orchestration rule to the project's `CLAUDE.md`, pre-approves the launcher in `.claude/settings.local.json`, and gitignores the logs and build worktrees. `/claudex-auto off` removes the rule and permission.

From the next session on, Claude delegates on its own:

| task size | what happens |
|---|---|
| trivial (typo, one-liner) | Claude does it |
| medium (2–4 files) | Claude writes a spec → one CLAUDEX builder |
| large (feature, refactor) | CLAUDEX risk pass → split into chunks → parallel CLAUDEX builders in worktrees → merge |
| unclear bug | CLAUDEX analysis → build with the diagnosis |
| after any build | tests → CLAUDEX JSON review → Claude confirms/refutes each finding |

Results are left uncommitted for you.

## Commands

| command | purpose |
|---|---|
| `/claudex-auto [on\|off]` | enable / disable automatic delegation in this project |
| `/claudex-build <task>` | force the build flow on one task |
| `/claudex <task>` | advisory flow: Claude writes the code, CLAUDEX advises and reviews |
| `/claudex-effort [review\|build] <level>` | set Codex reasoning effort (minimal, low, medium, high, xhigh) |
| `/claudex-status` | running builders/reviews, recent runs with duration and tokens, build worktrees |
| `/claudex-cancel [--keep-worktrees]` | stop every running CLAUDEX process and clean up worktrees and branches |

## Reasoning effort and timeouts

| mode | default effort | default timeout | overrides |
|---|---|---|---|
| exec (questions, risk passes) | low | 480 s | `-e`, `CLAUDEX_EFFORT`, `effort=` |
| review | medium | 480 s | `CLAUDEX_REVIEW_EFFORT`, `review_effort=` |
| build | high | 1200 s | `CLAUDEX_BUILD_EFFORT`, `build_effort=`, `build_timeout=` |

`key=value` lines live in `.claude/claudex.conf` in the project. Review runs with a workspace-write sandbox so Codex can run your tests; set `review_sandbox=read-only` to forbid that. The Codex model itself comes from `~/.codex/config.toml`.

## Wrapper

`scripts/claudex` is a plain bash script around `codex exec`. Modes: default (question), `review`, `build`. Useful flags: `-C DIR`, `-e EFFORT`, `-t SECS`, `-v` (full transcript), `--json` (structured review), `-w` / `--ro` (sandbox). Transcripts persist in `.claude/claudex-logs/` (last 40 runs).

JSON reviews report `coverage`: files actually opened, commands run, whether tests ran, their result, and confidence with a reason. The wrapper independently measures transcript `exec_count`, `tests_detected`, and `patched` (distinct paths in apply-patch blocks). Valid JSON output includes these under `measured`; plain reviews and invalid JSON get `[claudex coverage: exec=N tests=yes|no patched=K]`. The existing log-path footer remains; remove it before parsing JSON (and omit `-v`). For JSON reviews the saved `.last.md` (the RESULT file the relay returns) is the merged document; the model's untouched answer is kept next to it as `.raw.md`. Review done/failed registry events include the measured fields, and detected patches trigger a warning. Test detection indicates a matching command, not a passing result.

Treat empty findings as low-confidence when no tests were detected, the model reports low confidence, or fewer than three exec calls were measured. Rerun at `-e high` or read the diff yourself, and state the coverage in your report.

The run registry lives in the main worktree, so `status` and `cancel` also work from linked worktrees and subdirectories. Cancellation checks process identity and marks mismatches as stale. Cleanup only removes worktrees inside the main worktree's `.claudex-wt/` whose branches start with `claudex/`.

## Update

```
/plugin marketplace update gryd
/plugin update claudex
```

then restart. Projects need no re-setup; the launcher resolves the newest installed version. If a release changes the CLAUDE.md rule, run `/claudex-auto` again to refresh it in place.

## Development

`scripts/test.sh` runs offline registry checks and live smoke tests against a temporary repo (live tests need a signed-in Codex, ~5 min). Use `bash scripts/test.sh --offline` to run only the checks that need no network.

## License

MIT
